open! Core

type t =
  { instrument : Instrument.t
  ; token : string
  ; units_per_contract : float
  ; units_per_price : float
  }
[@@deriving sexp_of, compare, equal]

let of_info (info : Instrument_info.t) =
  Option.map (Instrument_info.units_per_contract info) ~f:(fun units_per_contract ->
    { instrument = info.instrument
    ; token = info.base
    ; units_per_contract
    ; units_per_price = info.units_per_price
    })
;;

let defaults = List.filter_map Instrument_info.catalogue ~f:of_info
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
