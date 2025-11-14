1) Regular (good broadband)
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

1) Test
fake_ping_lag_send: 30
fake_ping_lag_recv: 30
fake_loss_send: 1
fake_loss_recv: 1
fake_jitter_send: 20
fake_jitter_recv: 20
fake_dup_send: 2
fake_dup_recv: 2
fake_dup_ms_max: 100
fake_reorder_send: 4
fake_reorder_recv: 4
fake_reorder_ms: 60

2) Medium laggy (congested Wi-Fi)
fake_ping_lag_send: 90
fake_ping_lag_recv: 90
fake_loss_send: 1
fake_loss_recv: 1
fake_jitter_send: 20
fake_jitter_recv: 20
fake_dup_send: 1
fake_dup_recv: 1
fake_dup_ms_max: 120
fake_reorder_send: 2
fake_reorder_recv: 2
fake_reorder_ms: 80

3) High laggy (bad mobile / bufferbloat)
fake_ping_lag_send: 220
fake_ping_lag_recv: 220
fake_loss_send: 5
fake_loss_recv: 5
fake_jitter_send: 50
fake_jitter_recv: 50
fake_dup_send: 3
fake_dup_recv: 3
fake_dup_ms_max: 250
fake_reorder_send: 10
fake_reorder_recv: 10
fake_reorder_ms: 150