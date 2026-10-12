(** How many units of the underlying token a venue's prices and sizes refer to, for
    comparing instruments across venues. Prices of [binance:1000PEPEUSDT] are per 1000
    PEPE and its sizes count lots of 1000; [okx:BTC-USDT-SWAP] quotes per BTC but its
    sizes count contracts of 0.01 BTC.

    Per token: [price / units_per_price] and [size * units_per_contract]. *)

open! Core

type t =
  { instrument : Instrument.t
  ; token : string (** the underlying asset, e.g. ["BTC"], ["PEPE"] *)
  ; units_per_contract : float (** tokens per unit of size *)
  ; units_per_price : float (** tokens the quoted price is for *)
  }
[@@deriving sexp_of, compare, equal]

(** The row of a catalogue entry; [None] for sizes in quote currency, whose token count
    depends on the price. *)
val of_info : Instrument_info.t -> t option

(** {!of_info} over {!Instrument_info.catalogue}. Not exhaustive: instruments missing
    there have no row in the [units_per_contract] table unless a CSV adds them. *)
val defaults : t list

(** [CREATE TABLE units_per_contract (venue, symbol, token, units_per_contract, units_per_price)]
    from [defaults], plus the rows of [csv] (same columns, with a header) when given; CSV
    rows replace defaults for the same venue and symbol. *)
val create_table_sql : ?csv:string -> unit -> string
