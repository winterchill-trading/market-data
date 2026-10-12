open! Core
open Market_data

let%expect_test "built-in catalogue" =
  List.iter Instrument_info.catalogue ~f:(fun (t : Instrument_info.t) ->
    printf
      !"%-26s %-6s %-17s funding %-4s tick %s lot %s\n"
      (Instrument.to_string t.instrument)
      (Sexp.to_string [%sexp (t.kind : Instrument_info.Kind.t)])
      (Sexp.to_string [%sexp (t.size_unit : Instrument_info.Size_unit.t)])
      (Option.value_map t.funding_interval ~default:"-" ~f:Time_ns.Span.to_string)
      (Price.to_string t.tick)
      (Size.to_string t.lot));
  [%expect
    {|
    hyperliquid:BTC            Perp   Base              funding 1h   tick 1 lot 0.00001
    hyperliquid:ETH            Perp   Base              funding 1h   tick 0.1 lot 0.0001
    hyperliquid:kPEPE          Perp   (Contracts 1000)  funding 1h   tick 0.000001 lot 1
    binance:1000PEPEUSDT       Perp   (Contracts 1000)  funding 8h   tick 0.0000001 lot 1
    binance:BTCUSDT            Perp   Base              funding 8h   tick 0.1 lot 0.001
    binance:ETHUSDT            Perp   Base              funding 8h   tick 0.01 lot 0.001
    bybit:1000PEPEUSDT         Perp   (Contracts 1000)  funding 8h   tick 0.0000001 lot 100
    bybit:BTCUSDT              Perp   Base              funding 8h   tick 0.1 lot 0.001
    bybit:ETHUSDT              Perp   Base              funding 8h   tick 0.01 lot 0.01
    okx:BTC-USDT-SWAP          Perp   (Contracts 0.01)  funding 8h   tick 0.1 lot 0.01
    okx:ETH-USDT-SWAP          Perp   (Contracts 0.1)   funding 8h   tick 0.01 lot 0.01
    coinbase:BTC-USD           Spot   Base              funding -    tick 0.01 lot 0.00000001
    coinbase:ETH-USD           Spot   Base              funding -    tick 0.01 lot 0.00000001
    kraken:BTC/USD             Spot   Base              funding -    tick 0.1 lot 0.00000001
    kraken:PF_XBTUSD           Perp   Base              funding 1h   tick 1 lot 0.0001
    deribit:BTC-PERPETUAL      Perp   Quote             funding 8h   tick 0.5 lot 10
    bitget:BTCUSDT             Perp   Base              funding 8h   tick 0.1 lot 0.0001
    |}]
;;

let%expect_test "every recorder example instrument is catalogued" =
  [ "hyperliquid:BTC"
  ; "hyperliquid:ETH"
  ; "binance:BTCUSDT"
  ; "binance:ETHUSDT"
  ; "bybit:BTCUSDT"
  ; "bybit:ETHUSDT"
  ; "okx:BTC-USDT-SWAP"
  ; "coinbase:BTC-USD"
  ; "kraken:BTC/USD"
  ; "kraken:PF_XBTUSD"
  ; "deribit:BTC-PERPETUAL"
  ; "bitget:BTCUSDT"
  ]
  |> List.filter ~f:(fun s ->
    Option.is_none (Instrument_info.lookup (Instrument.of_string s)))
  |> [%sexp_of: string list]
  |> print_s;
  [%expect {| () |}]
;;

let%expect_test "parse, defaults, round trip and errors" =
  let show s =
    match Instrument_info.of_string s with
    | Ok ts ->
      List.iter ts ~f:(fun t ->
        print_s [%sexp (t : Instrument_info.t)];
        print_s
          [%sexp
            (Instrument_info.units_per_contract t : float option)
            , (t.units_per_price : float)
            , ([%equal: Instrument_info.t]
                 t
                 (Instrument_info.t_of_sexp (Instrument_info.sexp_of_t t))
               : bool)])
    | Error e -> print_s [%sexp (e : Error.t)]
  in
  show
    {|(((venue Okx) (symbol BTC-USDT-SWAP) (kind Perp) (base BTC) (quote USDT)
       (size_unit (Contracts 0.01)) (funding_interval 8h) (tick 0.1) (lot 0.01))
      ((venue Deribit) (symbol BTC-PERPETUAL) (kind Perp) (base BTC) (quote USD)
       (size_unit Quote) (tick 0.5) (lot 10)))|};
  [%expect
    {|
    ((venue Okx) (symbol BTC-USDT-SWAP) (kind Perp) (base BTC) (quote USDT)
     (size_unit (Contracts 0.01)) (funding_interval 8h) (tick 0.1) (lot 0.01))
    ((0.01) 1 true)
    ((venue Deribit) (symbol BTC-PERPETUAL) (kind Perp) (base BTC) (quote USD)
     (size_unit Quote) (tick 0.5) (lot 10))
    (() 1 true)
    |}];
  show
    {|(((venue Okx) (symbol X) (kind Spot) (base X) (quote Y) (size_unit Base) (tick 1) (lot 1))
      ((venue Okx) (symbol X) (kind Spot) (base X) (quote Y) (size_unit Base) (tick 1) (lot 1)))|};
  [%expect {| ("Instrument_info: duplicate instrument" ((venue Okx) (symbol X))) |}];
  show
    {|(((venue Okx) (symbol X) (kind Spot) (base X) (quote Y) (size_unit (Contracts 0)) (tick 1) (lot 1)))|};
  [%expect
    {|
    (Of_sexp_error "Instrument_info: contract multiplier must be positive"
     (invalid_sexp
      ((venue Okx) (symbol X) (kind Spot) (base X) (quote Y)
       (size_unit (Contracts 0)) (tick 1) (lot 1)))
     (containing_sexp
      (((venue Okx) (symbol X) (kind Spot) (base X) (quote Y)
        (size_unit (Contracts 0)) (tick 1) (lot 1)))))
    |}]
;;
