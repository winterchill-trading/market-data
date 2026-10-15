open! Core
module Float_u = Stdlib_upstream_compatible.Float_u

module Event = struct
  type t =
    { direction : Directional_change.Direction.t
    ; time : Time_ns.t
    ; price : Price.t
    ; sum : float
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { mutable started : bool
  ; mutable last : Price.t
  ; h : Float_u.t
  ; mutable pos : Float_u.t
  ; mutable neg : Float_u.t
  }

let create ~threshold =
  if not (Float.is_finite threshold && Float.( > ) threshold 0.)
  then
    raise_s
      [%message "Cusum_filter.create: threshold must be positive" (threshold : float)];
  { started = false
  ; last = Price.zero
  ; h = Float_u.of_float threshold
  ; pos = #0.
  ; neg = #0.
  }
;;

let threshold t = Float_u.to_float t.h

let add t ~time price =
  if not t.started
  then (
    t.started <- true;
    t.last <- price;
    Null)
  else (
    let r =
      Float_u.log
        (Float_u.div
           (Float_u.of_int (Price.to_units price))
           (Float_u.of_int (Price.to_units t.last)))
    in
    t.last <- price;
    t.pos <- Float_u.max #0. (Float_u.add t.pos r);
    t.neg <- Float_u.min #0. (Float_u.add t.neg r);
    if Float_u.compare t.pos t.h >= 0
    then (
      let sum = Float_u.to_float t.pos in
      t.pos <- #0.;
      This { Event.direction = Up; time; price; sum })
    else if Float_u.compare t.neg (Float_u.neg t.h) <= 0
    then (
      let sum = Float_u.to_float t.neg in
      t.neg <- #0.;
      This { Event.direction = Down; time; price; sum })
    else Null)
;;

let add_trade t (trade : Trade.t) = add t ~time:trade.exch_ts trade.price

let of_prices ~threshold prices =
  let t = create ~threshold in
  List.filter_map prices ~f:(fun (time, price) ->
    match add t ~time price with
    | This e -> Some e
    | Null -> None)
;;
