open! Core
open! Async
open Market_data

let%expect_test "merges sorted pipes, ties by input order" =
  let input l = Pipe.of_list l in
  let merged =
    Merge.sorted
      ~compare:(fun (a, _) (b, _) -> Int.compare a b)
      [ input [ 1, "a"; 4, "a"; 9, "a" ]; input []; input [ 1, "c"; 2, "c"; 9, "c" ] ]
  in
  let%map l = Pipe.to_list merged in
  print_s [%sexp (l : (int * string) list)];
  [%expect {| ((1 a) (1 c) (2 c) (4 a) (9 a) (9 c)) |}]
;;

let%test_unit "quickcheck: merge equals stable sort of the concatenation" =
  Quickcheck.test
    ~sexp_of:[%sexp_of: int list list]
    (Quickcheck.Generator.list (Quickcheck.Generator.list Int.quickcheck_generator))
    ~f:(fun lists ->
      let lists = List.map lists ~f:(List.sort ~compare:Int.compare) in
      let merged =
        Thread_safe.block_on_async_exn (fun () ->
          Pipe.to_list
            (Merge.sorted ~compare:Int.compare (List.map lists ~f:Pipe.of_list)))
      in
      [%test_result: int list]
        merged
        ~expect:(List.sort (List.concat lists) ~compare:Int.compare))
;;
