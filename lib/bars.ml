open! Core
module Float_u = Stdlib_upstream_compatible.Float_u

module Measure = struct
  type t =
    | Ticks
    | Volume
    | Dollar
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Ticks -> "tick"
    | Volume -> "volume"
    | Dollar -> "dollar"
  ;;

  let of_string s = List.find all ~f:(fun t -> String.equal (to_string t) s)
end

module Adaptive = struct
  type t =
    { warmup_ticks : int
    ; span : int
    ; min_ticks : int
    ; max_ticks : int
    }
  [@@deriving sexp, compare, equal]

  let default ~warmup_ticks =
    { warmup_ticks
    ; span = 20
    ; min_ticks = Int.max 1 (warmup_ticks / 10)
    ; max_ticks = warmup_ticks * 10
    }
  ;;

  let validate t =
    if t.span >= 1
       && 1 <= t.min_ticks
       && t.min_ticks <= t.warmup_ticks
       && t.warmup_ticks <= t.max_ticks
    then Ok ()
    else
      Or_error.error_s
        [%message
          "Bars: adaptive bars need span >= 1 and 1 <= min_ticks <= warmup_ticks <= \
           max_ticks"
            ~_:(t : t)]
  ;;
end

module Spec = struct
  type t =
    | Tick of int
    | Volume of Size.t
    | Dollar of float
    | Imbalance of Measure.t * Adaptive.t
    | Run of Measure.t * Adaptive.t
  [@@deriving sexp, compare, equal]

  let validate t =
    let positive ok =
      if ok
      then Ok t
      else Or_error.error_s [%message "Bars: threshold must be positive" ~_:(t : t)]
    in
    match t with
    | Tick n -> positive (n >= 1)
    | Volume s -> positive (Size.is_positive s)
    | Dollar x -> positive (Float.is_finite x && Float.( > ) x 0.)
    | Imbalance (_, a) | Run (_, a) ->
      Adaptive.validate a |> Or_error.map ~f:(fun () -> t)
  ;;

  let float_label x =
    if Float.is_integer x && Float.( < ) (Float.abs x) 1e15
    then sprintf "%.0f" x
    else sprintf "%g" x
  ;;

  let to_string = function
    | Tick n -> sprintf "tick-%d" n
    | Volume s -> "volume-" ^ Size.to_string s
    | Dollar x -> "dollar-" ^ float_label x
    | Imbalance (m, a) -> sprintf "%s-imbalance-%d" (Measure.to_string m) a.warmup_ticks
    | Run (m, a) -> sprintf "%s-run-%d" (Measure.to_string m) a.warmup_ticks
  ;;

  let of_string s =
    let fail () = Or_error.error_s [%message "Bars: unknown bar spec" s] in
    match String.lsplit2 s ~on:':' with
    | None -> fail ()
    | Some (kind, arg) ->
      Or_error.try_with_join (fun () ->
        match kind with
        | "tick" -> validate (Tick (Int.of_string arg))
        | "volume" -> validate (Volume (Size.of_string arg))
        | "dollar" -> validate (Dollar (Float.of_string arg))
        | _ ->
          let adaptive m make =
            match Measure.of_string m with
            | None -> fail ()
            | Some m ->
              validate (make m (Adaptive.default ~warmup_ticks:(Int.of_string arg)))
          in
          (match String.rsplit2 kind ~on:'-' with
           | Some (m, "imbalance") -> adaptive m (fun m a -> Imbalance (m, a))
           | Some (m, "run") -> adaptive m (fun m a -> Run (m, a))
           | _ -> fail ()))
  ;;
end

module Bar = struct
  module Stable = struct
    module V1 = struct
      type t =
        { instrument : Instrument.Stable.V1.t
        ; first_ts : Time_ns.Stable.V1.t
        ; last_ts : Time_ns.Stable.V1.t
        ; open_ : Price.Stable.V1.t
        ; high : Price.Stable.V1.t
        ; low : Price.Stable.V1.t
        ; close : Price.Stable.V1.t
        ; volume : Size.Stable.V1.t
        ; buy_volume : Size.Stable.V1.t
        ; notional : float
        ; trade_count : int
        ; threshold : float
        }
      [@@deriving bin_io, sexp, compare, equal, quickcheck]
    end
  end

  type t = Stable.V1.t =
    { instrument : Instrument.t
    ; first_ts : Time_ns.t
    ; last_ts : Time_ns.t
    ; open_ : Price.t
    ; high : Price.t
    ; low : Price.t
    ; close : Price.t
    ; volume : Size.t
    ; buy_volume : Size.t
    ; notional : float
    ; trade_count : int
    ; threshold : float
    }
  [@@deriving bin_io, sexp, compare, equal, fields]
end

(* The unboxed fields come last; every update writes them in place, so adding a trade that
   closes no bar allocates nothing. *)
type t =
  { instrument : Instrument.t
  ; spec : Spec.t
  ; mutable count : int
  ; mutable first_ts : Time_ns.t
  ; mutable last_ts : Time_ns.t
  ; mutable open_ : Price.t
  ; mutable high : Price.t
  ; mutable low : Price.t
  ; mutable close : Price.t
  ; mutable volume : Size.t
  ; mutable buy_volume : Size.t
  ; mutable bars : int (** closed so far *)
  ; mutable notional : Float_u.t
  ; mutable signed : Float_u.t (** sum of b * v *)
  ; mutable buy_measure : Float_u.t
  ; mutable sell_measure : Float_u.t
  ; mutable expected_ticks : Float_u.t
  ; mutable expected_signed : Float_u.t (** per trade *)
  ; mutable expected_buy : Float_u.t (** per trade *)
  ; mutable expected_sell : Float_u.t (** per trade *)
  }

let create instrument spec =
  let spec = Spec.validate spec |> ok_exn in
  { instrument
  ; spec
  ; count = 0
  ; first_ts = Time_ns.epoch
  ; last_ts = Time_ns.epoch
  ; open_ = Price.zero
  ; high = Price.zero
  ; low = Price.zero
  ; close = Price.zero
  ; volume = Size.zero
  ; buy_volume = Size.zero
  ; bars = 0
  ; notional = #0.
  ; signed = #0.
  ; buy_measure = #0.
  ; sell_measure = #0.
  ; expected_ticks = #0.
  ; expected_signed = #0.
  ; expected_buy = #0.
  ; expected_sell = #0.
  }
;;

let instrument t = t.instrument
let spec t = t.spec

(* Price and size units are 10^-8. *)
let of_units u = Float_u.mul (Float_u.of_int u) #0.00000001
let ge a b = Float_u.compare a b >= 0

let measure (m : Measure.t) ~price ~size =
  match m with
  | Ticks -> #1.
  | Volume -> size
  | Dollar -> Float_u.mul price size
;;

let threshold_u t =
  match t.spec with
  | Tick n -> Float_u.of_int n
  | Volume s -> of_units (Size.to_units s)
  | Dollar x -> Float_u.of_float x
  | Imbalance _ ->
    if t.bars = 0
    then Float_u.of_float Float.infinity
    else Float_u.mul t.expected_ticks (Float_u.abs t.expected_signed)
  | Run _ ->
    if t.bars = 0
    then Float_u.of_float Float.infinity
    else Float_u.mul t.expected_ticks (Float_u.max t.expected_buy t.expected_sell)
;;

let threshold t = Float_u.to_float (threshold_u t)

let reached t =
  match t.spec with
  | Tick n -> t.count >= n
  | Volume s -> Size.( >= ) t.volume s
  | Dollar x -> ge t.notional (Float_u.of_float x)
  | Imbalance (_, a) ->
    if t.bars = 0
    then t.count >= a.warmup_ticks
    else t.count >= a.min_ticks && ge (Float_u.abs t.signed) (threshold_u t)
  | Run (_, a) ->
    if t.bars = 0
    then t.count >= a.warmup_ticks
    else
      t.count >= a.min_ticks
      && ge (Float_u.max t.buy_measure t.sell_measure) (threshold_u t)
;;

(* The threshold a closing bar records: its trade count for a warm-up bar. *)
let closing_threshold t =
  match t.spec with
  | (Imbalance _ | Run _) when t.bars = 0 -> Float_u.of_int t.count
  | _ -> threshold_u t
;;

let to_bar t ~threshold : Bar.t =
  { instrument = t.instrument
  ; first_ts = t.first_ts
  ; last_ts = t.last_ts
  ; open_ = t.open_
  ; high = t.high
  ; low = t.low
  ; close = t.close
  ; volume = t.volume
  ; buy_volume = t.buy_volume
  ; notional = Float_u.to_float t.notional
  ; trade_count = t.count
  ; threshold = Float_u.to_float threshold
  }
;;

let update_expectations t =
  match t.spec with
  | Tick _ | Volume _ | Dollar _ -> ()
  | Imbalance (_, a) | Run (_, a) ->
    let n = Float_u.of_int t.count in
    let alpha = Float_u.div #2. (Float_u.of_int (a.span + 1)) in
    let first = t.bars = 0 in
    let ewma prev x =
      if first then x else Float_u.add prev (Float_u.mul alpha (Float_u.sub x prev))
    in
    t.expected_ticks
    <- Float_u.min
         (Float_u.of_int a.max_ticks)
         (Float_u.max (Float_u.of_int a.min_ticks) (ewma t.expected_ticks n));
    t.expected_signed <- ewma t.expected_signed (Float_u.div t.signed n);
    t.expected_buy <- ewma t.expected_buy (Float_u.div t.buy_measure n);
    t.expected_sell <- ewma t.expected_sell (Float_u.div t.sell_measure n)
;;

let reset t =
  t.count <- 0;
  t.volume <- Size.zero;
  t.buy_volume <- Size.zero;
  t.notional <- #0.;
  t.signed <- #0.;
  t.buy_measure <- #0.;
  t.sell_measure <- #0.
;;

let add t (trade : Trade.t) =
  let price = trade.price in
  let size = trade.size in
  if t.count = 0
  then (
    t.first_ts <- trade.exch_ts;
    t.open_ <- price;
    t.high <- price;
    t.low <- price)
  else (
    if Price.( > ) price t.high then t.high <- price;
    if Price.( < ) price t.low then t.low <- price);
  t.close <- price;
  t.last_ts <- trade.exch_ts;
  t.count <- t.count + 1;
  t.volume <- Size.( + ) t.volume size;
  let price_f = of_units (Price.to_units price) in
  let size_f = of_units (Size.to_units size) in
  t.notional <- Float_u.add t.notional (Float_u.mul price_f size_f);
  (match trade.side with
   | Buy -> t.buy_volume <- Size.( + ) t.buy_volume size
   | Sell -> ());
  (match t.spec with
   | Imbalance (m, _) | Run (m, _) ->
     let v = measure m ~price:price_f ~size:size_f in
     (match trade.side with
      | Buy ->
        t.signed <- Float_u.add t.signed v;
        t.buy_measure <- Float_u.add t.buy_measure v
      | Sell ->
        t.signed <- Float_u.sub t.signed v;
        t.sell_measure <- Float_u.add t.sell_measure v)
   | Tick _ | Volume _ | Dollar _ -> ());
  if reached t
  then (
    let bar = to_bar t ~threshold:(closing_threshold t) in
    update_expectations t;
    t.bars <- t.bars + 1;
    reset t;
    This bar)
  else Null
;;

let current t = if t.count = 0 then None else Some (to_bar t ~threshold:(threshold_u t))

let of_trades instrument spec trades =
  let t = create instrument spec in
  let closed =
    List.filter_map trades ~f:(fun trade ->
      match add t trade with
      | This bar -> Some bar
      | Null -> None)
  in
  closed @ Option.to_list (current t)
;;
