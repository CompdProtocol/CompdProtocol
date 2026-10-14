// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Pure executable evidence for the frozen BNB backing equations; no production code is imported or modified.
contract CompdEmergencyBackingMathC2G1Test {
    struct State { uint256 sc; uint256 br; uint256 pr; uint256 hr; uint256 aq; uint256 ap; uint256 vb; }

    function _state(uint256 sc,uint256 br,uint256 pr,uint256 hr,uint256 ap,uint256 vb) private pure returns(State memory s) {
        require(ap<=sc,"active principal exceeds strategy capital");
        uint256 buckets=sc+br+pr+hr;
        require(ap<=buckets,"invalid state");
        s=State(sc,br,pr,hr,buckets-ap,ap,vb);
    }
    function _netNonHolder(State memory s) private pure returns(uint256){return s.aq-s.hr;}
    function _available(State memory s) private pure returns(uint256){uint256 n=_netNonHolder(s);uint256 free=s.vb>n?s.vb-n:0;return free<s.hr?free:s.hr;}
    function _deficit(State memory s) private pure returns(uint256){return s.hr-_available(s);}
    function _invariant(State memory s) private pure {require(s.sc+s.br+s.pr+s.hr==s.aq+s.ap,"bucket invariant");require(s.aq>=s.hr,"derived AQ>=HR");require(s.ap<=s.sc,"principal subset");}
    function _eq(uint256 a,uint256 b) private pure {require(a==b,"unexpected value");}

    function testFuzz_RecommendedFormulaAndDerivedAQBound(uint96 sc0,uint96 br0,uint96 pr0,uint96 hr0,uint96 ap0,uint96 vb0) public pure {
        uint256 sc=uint256(sc0);uint256 br=uint256(br0);uint256 pr=uint256(pr0);uint256 hr=uint256(hr0);
        uint256 ap=sc==0?0:uint256(ap0)%(sc+1);State memory s=_state(sc,br,pr,hr,ap,uint256(vb0));_invariant(s);
        uint256 expectedN=(sc-ap)+br+pr;_eq(s.aq-s.hr,expectedN);
        uint256 available=_available(s);require(available<=hr,"backing exceeds reserve");_eq(_deficit(s),hr-available);
        if(s.vb>=s.aq)_eq(available,hr);
        if(s.vb<=expectedN)_eq(available,0);
    }

    function testCase1_IdleNoActivePrincipal() public pure {
        State memory s=_state(200,20,30,10,0,260);_invariant(s);_eq(s.aq,260);_eq(_netNonHolder(s),250);_eq(_available(s),10);_eq(_deficit(s),0);
    }
    function testCase2_ActivePrincipalButHolderFullyBacked() public pure {
        // Allocate 100 of Strategy Capital: SC is unchanged; AQ and Vault BNB fall; AP rises.
        State memory s=_state(200,20,30,10,100,160);_invariant(s);_eq(s.aq,160);_eq(_netNonHolder(s),150);_eq(_available(s),10);_eq(_deficit(s),0);
    }
    function testCase3_NonHolderPhysicalLiquidityBelowAccounting() public pure {
        State memory s=_state(200,20,30,10,100,140);_invariant(s);_eq(s.aq,160);_eq(_netNonHolder(s),150);_eq(_available(s),0);_eq(_deficit(s),10);
    }
    function testCase4_HolderReserveUnderbackedBeforeEmergencyEntry() public pure {
        State memory s=_state(200,20,30,10,100,155);_invariant(s);_eq(s.aq,160);_eq(_netNonHolder(s),150);_eq(_available(s),5);_eq(_deficit(s),5);
        // The prior VB >= AQ emergency-entry guard rejects this state (155 < 160).
        require(s.vb<s.aq,"case must be pre-entry underbacking");
    }
    function testCase5_ProfitableSynchronousReturn() public pure {
        // 100 principal returns 120: profit 20 -> SC 13, BR 3, HR 2, PR 2.
        State memory before_= _state(200,20,30,10,100,160);_invariant(before_);
        State memory after_=_state(213,23,32,12,0,280);_invariant(after_);_eq(after_.aq,280);_eq(_available(after_),12);_eq(_deficit(after_),0);
    }
    function testCase6_LosingSynchronousReturn() public pure {
        // 100 principal returns 80: 20 loss reduces SC only; no profit buckets are credited.
        State memory before_=_state(200,20,30,10,100,160);_invariant(before_);
        State memory after_=_state(180,20,30,10,0,240);_invariant(after_);_eq(after_.aq,240);_eq(_available(after_),10);_eq(_deficit(after_),0);
    }
    function testCase7_HolderPaymentImmediatelyBeforeEmergency() public pure {
        // Exact payment 4 reduces HR, AQ and physical BNB together.
        State memory s=_state(200,20,30,6,0,256);_invariant(s);_eq(s.aq,256);_eq(_netNonHolder(s),250);_eq(_available(s),6);_eq(_deficit(s),0);
    }
    function testCase8_AccountedEmergencyRecoveryAfterSnapshot() public pure {
        State memory pre=_state(200,20,30,10,0,260);_invariant(pre);uint256 preDeficit=_deficit(pre);_eq(preDeficit,0);
        // A 10 BNB Protocol Reserve recovery debits PR, AQ and VB atomically.
        State memory post=_state(200,20,20,10,0,250);_invariant(post);_eq(post.aq,250);_eq(_netNonHolder(post),240);_eq(_available(post),10);_eq(_deficit(post),0);_eq(_deficit(post)>preDeficit?_deficit(post)-preDeficit:0,0);
    }
    function testAggregateIdentityAloneDoesNotProveAQgeHR() public pure {
        // Algebraic counterexample if AP is not constrained to be Strategy Capital.
        uint256 sc=10;uint256 br=0;uint256 pr=0;uint256 hr=90;uint256 aq=0;uint256 ap=100;
        _eq(sc+br+pr+hr,aq+ap);require(ap>sc&&aq<hr,"counterexample missing");
        // This is not a reachable canonical state: AP is a subset of SC, hence AP <= SC.
    }
}
