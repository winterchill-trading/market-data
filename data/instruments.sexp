;; Instrument catalogue: one entry per (venue, symbol), read by Instrument_info.
;;
;; kind              Spot | Perp | Future | Option
;; base, quote       the underlying asset and the currency prices are quoted in
;; size_unit         Base: sizes count base tokens
;;                   Quote: sizes count quote currency (inverse contracts)
;;                   (Contracts m): sizes count contracts of m base tokens
;; units_per_price   base tokens the quoted price is for (default 1)
;; funding_interval  what one funding rate print covers (perpetuals only)
;; tick, lot         minimum price and size increments
;;
;; Values are the venues' published contract specs at the time of writing; they
;; change, so check before trusting a tick or lot for order placement.
((;; Hyperliquid: hourly funding; ticks follow 5 significant figures.
  (venue Hyperliquid) (symbol BTC) (kind Perp) (base BTC) (quote USD)
  (size_unit Base) (funding_interval 1h) (tick 1) (lot 0.00001))
 ((venue Hyperliquid) (symbol ETH) (kind Perp) (base ETH) (quote USD)
  (size_unit Base) (funding_interval 1h) (tick 0.1) (lot 0.0001))
 ((venue Hyperliquid) (symbol kPEPE) (kind Perp) (base PEPE) (quote USD)
  (size_unit (Contracts 1000)) (units_per_price 1000) (funding_interval 1h)
  (tick 0.000001) (lot 1))
 ;; Binance USD-M futures.
 ((venue Binance) (symbol BTCUSDT) (kind Perp) (base BTC) (quote USDT)
  (size_unit Base) (funding_interval 8h) (tick 0.1) (lot 0.001))
 ((venue Binance) (symbol ETHUSDT) (kind Perp) (base ETH) (quote USDT)
  (size_unit Base) (funding_interval 8h) (tick 0.01) (lot 0.001))
 ((venue Binance) (symbol 1000PEPEUSDT) (kind Perp) (base PEPE) (quote USDT)
  (size_unit (Contracts 1000)) (units_per_price 1000) (funding_interval 8h)
  (tick 0.0000001) (lot 1))
 ;; Bybit linear perpetuals.
 ((venue Bybit) (symbol BTCUSDT) (kind Perp) (base BTC) (quote USDT)
  (size_unit Base) (funding_interval 8h) (tick 0.1) (lot 0.001))
 ((venue Bybit) (symbol ETHUSDT) (kind Perp) (base ETH) (quote USDT)
  (size_unit Base) (funding_interval 8h) (tick 0.01) (lot 0.01))
 ((venue Bybit) (symbol 1000PEPEUSDT) (kind Perp) (base PEPE) (quote USDT)
  (size_unit (Contracts 1000)) (units_per_price 1000) (funding_interval 8h)
  (tick 0.0000001) (lot 100))
 ;; OKX swaps: sizes count contracts (ctVal).
 ((venue Okx) (symbol BTC-USDT-SWAP) (kind Perp) (base BTC) (quote USDT)
  (size_unit (Contracts 0.01)) (funding_interval 8h) (tick 0.1) (lot 0.01))
 ((venue Okx) (symbol ETH-USDT-SWAP) (kind Perp) (base ETH) (quote USDT)
  (size_unit (Contracts 0.1)) (funding_interval 8h) (tick 0.01) (lot 0.01))
 ;; Coinbase Advanced Trade spot.
 ((venue Coinbase) (symbol BTC-USD) (kind Spot) (base BTC) (quote USD)
  (size_unit Base) (tick 0.01) (lot 0.00000001))
 ((venue Coinbase) (symbol ETH-USD) (kind Spot) (base ETH) (quote USD)
  (size_unit Base) (tick 0.01) (lot 0.00000001))
 ;; Kraken: spot pair for the book, futures perpetual for funding (hourly).
 ((venue Kraken) (symbol BTC/USD) (kind Spot) (base BTC) (quote USD)
  (size_unit Base) (tick 0.1) (lot 0.00000001))
 ((venue Kraken) (symbol PF_XBTUSD) (kind Perp) (base BTC) (quote USD)
  (size_unit Base) (funding_interval 1h) (tick 1) (lot 0.0001))
 ;; Deribit: amounts are USD notional; funding accrues continuously and the
 ;; feed reports the 8h equivalent.
 ((venue Deribit) (symbol BTC-PERPETUAL) (kind Perp) (base BTC) (quote USD)
  (size_unit Quote) (funding_interval 8h) (tick 0.5) (lot 10))
 ;; Bitget USDT-M futures.
 ((venue Bitget) (symbol BTCUSDT) (kind Perp) (base BTC) (quote USDT)
  (size_unit Base) (funding_interval 8h) (tick 0.1) (lot 0.0001)))
