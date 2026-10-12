open! Core

module Kind = struct
  type t =
    | Spot
    | Perp
    | Future
    | Option
  [@@deriving sexp, compare, equal, enumerate]
end

module Size_unit = struct
  type t =
    | Base
    | Quote
    | Contracts of float
  [@@deriving sexp, compare, equal]
end

type t =
  { instrument : Instrument.t
  ; kind : Kind.t
  ; base : string
  ; quote : string
  ; size_unit : Size_unit.t
  ; units_per_price : float
  ; funding_interval : Time_ns.Span.t option
  ; tick : Price.t
  ; lot : Size.t
  }
[@@deriving compare, equal]

module Repr = struct
  type t =
    { venue : Venue.t
    ; symbol : Symbol.t
    ; kind : Kind.t
    ; base : string
    ; quote : string
    ; size_unit : Size_unit.t
    ; units_per_price : float [@default 1.] [@sexp_drop_default.equal]
    ; funding_interval : Time_ns.Span.t option [@sexp.option]
    ; tick : Price.t
    ; lot : Size.t
    }
  [@@deriving sexp]
end

let t_of_sexp sexp =
  let { Repr.venue
      ; symbol
      ; kind
      ; base
      ; quote
      ; size_unit
      ; units_per_price
      ; funding_interval
      ; tick
      ; lot
      }
    =
    Repr.t_of_sexp sexp
  in
  if Float.( <= ) units_per_price 0.
  then of_sexp_error "Instrument_info: units_per_price must be positive" sexp;
  (match size_unit with
   | Contracts m when Float.( <= ) m 0. ->
     of_sexp_error "Instrument_info: contract multiplier must be positive" sexp
   | _ -> ());
  { instrument = { venue; symbol }
  ; kind
  ; base
  ; quote
  ; size_unit
  ; units_per_price
  ; funding_interval
  ; tick
  ; lot
  }
;;

let sexp_of_t
  { instrument = { venue; symbol }
  ; kind
  ; base
  ; quote
  ; size_unit
  ; units_per_price
  ; funding_interval
  ; tick
  ; lot
  }
  =
  Repr.sexp_of_t
    { venue
    ; symbol
    ; kind
    ; base
    ; quote
    ; size_unit
    ; units_per_price
    ; funding_interval
    ; tick
    ; lot
    }
;;

let units_per_contract t =
  match t.size_unit with
  | Base -> Some 1.
  | Contracts m -> Some m
  | Quote -> None
;;

let of_string s =
  let%bind.Or_error entries =
    Or_error.try_with (fun () -> Sexp.of_string_conv_exn s [%of_sexp: t list])
  in
  let sorted =
    List.sort entries ~compare:(fun a b -> Instrument.compare a.instrument b.instrument)
  in
  match
    List.find_a_dup sorted ~compare:(fun a b ->
      Instrument.compare a.instrument b.instrument)
  with
  | Some dup ->
    Or_error.error_s
      [%message
        "Instrument_info: duplicate instrument" ~_:(dup.instrument : Instrument.t)]
  | None -> Ok sorted
;;

let load path =
  Or_error.try_with_join (fun () -> of_string (In_channel.read_all path))
  |> Or_error.tag ~tag:path
;;

let catalogue = Or_error.ok_exn (of_string Instruments_data.contents)

let lookup ?(catalogue = catalogue) instrument =
  List.find catalogue ~f:(fun t -> Instrument.equal t.instrument instrument)
;;
