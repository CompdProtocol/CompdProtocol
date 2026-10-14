import unittest

from public_status import dashboard_projection, response_for_path


class DashboardApiTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = {
            'publicSnapshot': {'chainId': 56, 'blockNumber': '0x10', 'blockHash': '0x' + '1' * 64},
            'ledger': {'strategyCapitalWei': '350', 'realizedProfitWei': '22', 'realizedLossWei': '7'},
            'xstocks': {
                'mode': 'OBSERVE_ONLY',
                'assets': [{'symbol': 'NVDAx', 'status': 'DISABLED_ROUTE_NOT_QUALIFIED'}],
                'blockers': ['LIVE_TRADING_NOT_AUTHORIZED'],
                'latestEvaluation': {'evaluatedAt': 100, 'results': [{'decision': 'NO_TRADE'}]},
                'observationHistory': [{'evaluatedAt': 100}],
                'positions': None,
            },
            'holderRewards': {'status': 'NOT_ACTIVATED_DRY_RUN_INDEXED', 'pendingLiabilitiesWei': '0'},
            'privateKey': 'must-never-project',
        }

    def test_projection_uses_existing_data_and_keeps_execution_disabled(self):
        result = dashboard_projection(self.snapshot)
        self.assertEqual(result['treasury']['balancesWei']['strategyCapitalWei'], '350')
        self.assertEqual(result['realizedPnl'], {
            'status': 'ONCHAIN_CUMULATIVE', 'profitWei': '22', 'lossWei': '7', 'netWei': '15'
        })
        self.assertEqual(result['qualifiedRoutes']['status'], 'NOT_QUALIFIED')
        self.assertFalse(result['agent']['liveExecutionEnabled'])
        self.assertEqual(result['strategyActivity']['history'], [{'evaluatedAt': 100}])
        self.assertEqual(result['verifiedTrades'], {
            'status': 'UNAVAILABLE_LIVE_EXECUTION_DISABLED', 'items': []
        })
        self.assertNotIn('privateKey', result)

    def test_missing_values_are_not_fabricated(self):
        self.snapshot['ledger']['realizedProfitWei'] = None
        self.snapshot['ledger']['realizedLossWei'] = None
        self.snapshot['holderRewards'] = None
        self.snapshot['xstocks'].pop('observationHistory')
        result = dashboard_projection(self.snapshot)
        self.assertEqual(result['realizedPnl']['status'], 'NOT_AVAILABLE')
        self.assertIsNone(result['realizedPnl']['netWei'])
        self.assertIn('NOT_VERIFIED', result['holderRewards']['status'])
        self.assertEqual(result['strategyActivity']['status'], 'NOT_AVAILABLE')

    def test_projection_rejects_incomplete_snapshot(self):
        with self.assertRaises(ValueError):
            dashboard_projection({'ledger': {}})

    def test_route_preserves_status_and_adds_one_dashboard_route(self):
        self.assertIs(response_for_path('/status', self.snapshot), self.snapshot)
        self.assertEqual(response_for_path('/api/dashboard', self.snapshot)['schemaVersion'], 1)
        self.assertIsNone(response_for_path('/api/admin', self.snapshot))


if __name__ == '__main__':
    unittest.main()
