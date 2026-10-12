-- Lead-lag between venues from the bbo table: for each venue pair (leader, follower)
-- quoting the same token, how long after a mid change on the leader the follower's mid
-- moves the same way.
--
--   market-data query -dir /data/md -file queries/lead_lag.sql
--
-- A mid change is a bbo row whose mid differs from the previous row of the same venue
-- and symbol (by recv_ts). Each leader change is matched (ASOF JOIN) to the follower's
-- first same-direction change at or after it; matches later than the window are
-- dropped. Times are recv_ts, the one clock all venues share. Because every venue is
-- also matched as a follower of every other, look for the pair whose median is small
-- and whose matched share is high: that direction is the lead. Needs the token_bbo view
-- (bbo plus units_per_contract).

SET VARIABLE lead_lag_window_ms = 1000;

WITH mids AS (
  SELECT token, venue, symbol, recv_ts, mid,
         mid - lag(mid) OVER (PARTITION BY venue, symbol ORDER BY recv_ts) AS move
  FROM token_bbo
),
changes AS (
  SELECT token, venue, recv_ts, sign(move) AS dir
  FROM mids WHERE move <> 0
),
pairs AS (
  SELECT DISTINCT a.token, a.venue AS leader, b.venue AS follower
  FROM (SELECT DISTINCT token, venue FROM changes) a
  JOIN (SELECT DISTINCT token, venue FROM changes) b
    ON a.token = b.token AND a.venue <> b.venue
),
leader_changes AS (
  SELECT p.leader, p.follower, c.token, c.recv_ts, c.dir
  FROM changes c JOIN pairs p ON c.token = p.token AND c.venue = p.leader
),
lags AS (
  SELECT l.token, l.leader, l.follower,
         (epoch_ns(f.recv_ts) - epoch_ns(l.recv_ts)) / 1e6 AS lag_ms
  FROM leader_changes l
  ASOF LEFT JOIN changes f
    ON f.token = l.token AND f.venue = l.follower AND f.dir = l.dir
   AND f.recv_ts >= l.recv_ts
)
SELECT token, leader, follower,
       count(*) AS leader_changes,
       count(lag_ms) FILTER (WHERE lag_ms <= getvariable('lead_lag_window_ms')) AS matched,
       round(matched / leader_changes, 3) AS matched_share,
       round(median(lag_ms) FILTER (WHERE lag_ms <= getvariable('lead_lag_window_ms')), 1)
         AS median_lag_ms,
       round(quantile_cont(lag_ms, 0.25)
               FILTER (WHERE lag_ms <= getvariable('lead_lag_window_ms')), 1) AS p25_ms,
       round(quantile_cont(lag_ms, 0.75)
               FILTER (WHERE lag_ms <= getvariable('lead_lag_window_ms')), 1) AS p75_ms
FROM lags
GROUP BY ALL
ORDER BY token, median_lag_ms, leader, follower;
