open! Core

type t =
  { instrument : Instrument.t
  ; token : string
  ; units_per_contract : float
  ; units_per_price : float
  }
[@@deriving sexp_of, compare, equal]

let v venue symbol token ~contract ~price =
  { instrument = Instrument.create venue symbol
  ; token
  ; units_per_contract = contract
  ; units_per_price = price
  }
;;

let defaults =
  [ v Binance "BTCUSDT" "BTC" ~contract:1. ~price:1.
  ; v Binance "ETHUSDT" "ETH" ~contract:1. ~price:1.
  ; v Binance "1000PEPEUSDT" "PEPE" ~contract:1000. ~price:1000.
  ; v Bybit "BTCUSDT" "BTC" ~contract:1. ~price:1.
  ; v Bybit "ETHUSDT" "ETH" ~contract:1. ~price:1.
  ; v Bybit "1000PEPEUSDT" "PEPE" ~contract:1000. ~price:1000.
  ; v Hyperliquid "BTC" "BTC" ~contract:1. ~price:1.
  ; v Hyperliquid "ETH" "ETH" ~contract:1. ~price:1.
  ; v Hyperliquid "kPEPE" "PEPE" ~contract:1000. ~price:1000.
  ; v Okx "BTC-USDT-SWAP" "BTC" ~contract:0.01 ~price:1.
  ; v Okx "ETH-USDT-SWAP" "ETH" ~contract:0.1 ~price:1.
  ; v Coinbase "BTC-USD" "BTC" ~contract:1. ~price:1.
  ; v Coinbase "ETH-USD" "ETH" ~contract:1. ~price:1.
  ]
;;

let quote s = "'" ^ String.substr_replace_all s ~pattern:"'" ~with_:"''" ^ "'"

let create_table_sql ?csv () =
  let values =
    List.map defaults ~f:(fun t ->
      sprintf
        "(%s, %s, %s, %s::DOUBLE, %s::DOUBLE)"
        (quote (Venue.to_string (Instrument.venue t.instrument)))
        (quote (Symbol.to_string (Instrument.symbol t.instrument)))
        (quote t.token)
        (Float.to_string_12 t.units_per_contract)
        (Float.to_string_12 t.units_per_price))
    |> String.concat ~sep:", "
  in
  let defaults =
    sprintf
      "SELECT * FROM (VALUES %s) AS d(venue, symbol, token, units_per_contract, \
       units_per_price)"
      values
  in
  let body =
    match csv with
    | None -> defaults
    | Some csv ->
      let csv =
        sprintf
          "SELECT venue::VARCHAR AS venue, symbol::VARCHAR AS symbol, token::VARCHAR AS \
           token, units_per_contract::DOUBLE AS units_per_contract, \
           units_per_price::DOUBLE AS units_per_price FROM read_csv(%s, header = true)"
          (quote csv)
      in
      sprintf
        "%s UNION ALL SELECT * FROM (%s) AS d WHERE NOT EXISTS (SELECT 1 FROM (%s) AS c \
         WHERE c.venue = d.venue AND c.symbol = d.symbol)"
        csv
        defaults
        csv
  in
  "CREATE TABLE units_per_contract AS " ^ body ^ ";"
;;
