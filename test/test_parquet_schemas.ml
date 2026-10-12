open! Core
open! Async
open Market_data

let level price size : L2_update.Level.t =
  { price = Price.of_string price; size = Size.of_string size }
;;

let%expect_test "an l2 update flattens to one row per level, bids first" =
  let update : L2_update.t =
    { instrument = Sample.btc
    ; exch_ts = Sample.ts 0
    ; recv_ts = Sample.ts 1
    ; kind = Delta
    ; bids = [ level "99.5" "1"; level "99" "0" ]
    ; asks = [ level "100.5" "2" ]
    }
  in
  List.iter (Parquet_schemas.L2_row.of_update ~seq:7 update) ~f:(fun r ->
    printf
      "seq=%d snapshot=%b %s level=%d %s @ %s\n"
      r.seq
      r.is_snapshot
      (Sexp.to_string [%sexp (r.side : Side.t)])
      r.level
      (Size.to_string r.size)
      (Price.to_string r.price));
  [%expect
    {|
    seq=7 snapshot=false Buy level=0 1 @ 99.5
    seq=7 snapshot=false Buy level=1 0 @ 99
    seq=7 snapshot=false Sell level=0 2 @ 100.5
    |}];
  print_s
    [%sexp
      (Parquet_schemas.L2_row.of_update ~seq:0 { update with bids = []; asks = [] }
       : Parquet_schemas.L2_row.t list)];
  [%expect {| () |}];
  return ()
;;

let%expect_test "decimal columns use the fixed-decimal scale" =
  printf
    "DECIMAL(%d, %d)\n"
    Parquet_schemas.decimal_precision
    Parquet_schemas.decimal_scale;
  [%expect {| DECIMAL(18, 8) |}];
  return ()
;;
