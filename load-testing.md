Load-testing presets are server-only. The total simulated RTT is
`fake_ping_lag_send + fake_ping_lag_recv`, and jitter values are applied
symmetrically so you can read them as one-sided deviations in milliseconds.

Toggle any preset with the matching `load_testing_<name>` boolean exported by
`low_level_network_handler.gd`. Flip `load_testing_off` to clear everything.

1) `load_testing_broadband` - Good broadband (~50 ms RTT)
fake_ping_lag_send: 25
fake_ping_lag_recv: 25
fake_loss_send: 0
fake_loss_recv: 0
fake_jitter_send: 5
fake_jitter_recv: 5
fake_dup_send: 0
fake_dup_recv: 0
fake_dup_ms_max: 60
fake_reorder_send: 0
fake_reorder_recv: 0
fake_reorder_ms: 30

2) `load_testing_wifi_light` - Lightly loaded Wi-Fi (~80 ms RTT)
fake_ping_lag_send: 40
fake_ping_lag_recv: 40
fake_loss_send: 0
fake_loss_recv: 0
fake_jitter_send: 12
fake_jitter_recv: 12
fake_dup_send: 0
fake_dup_recv: 0
fake_dup_ms_max: 0
fake_reorder_send: 0
fake_reorder_recv: 0
fake_reorder_ms: 0

3) `load_testing_wifi_congested` - Congested Wi-Fi (~130 ms RTT)
fake_ping_lag_send: 65
fake_ping_lag_recv: 65
fake_loss_send: 1
fake_loss_recv: 1
fake_jitter_send: 20
fake_jitter_recv: 20
fake_dup_send: 1
fake_dup_recv: 1
fake_dup_ms_max: 110
fake_reorder_send: 2
fake_reorder_recv: 2
fake_reorder_ms: 70

4) `load_testing_mobile_average` - Average mobile (~200 ms RTT)
fake_ping_lag_send: 100
fake_ping_lag_recv: 100
fake_loss_send: 2
fake_loss_recv: 2
fake_jitter_send: 30
fake_jitter_recv: 30
fake_dup_send: 1
fake_dup_recv: 1
fake_dup_ms_max: 150
fake_reorder_send: 3
fake_reorder_recv: 3
fake_reorder_ms: 110

5) `load_testing_mobile_bufferbloat` - Heavily buffered mobile (~280 ms RTT)
fake_ping_lag_send: 140
fake_ping_lag_recv: 140
fake_loss_send: 3
fake_loss_recv: 3
fake_jitter_send: 45
fake_jitter_recv: 45
fake_dup_send: 2
fake_dup_recv: 2
fake_dup_ms_max: 190
fake_reorder_send: 5
fake_reorder_recv: 5
fake_reorder_ms: 150