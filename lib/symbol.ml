open! Core
module Bin = Binable.Of_stringable_without_uuid [@alert "-legacy"] (Exchange_core.Symbol)

module Stable = struct
  module V1 = struct
    include Exchange_core.Symbol
    include Bin

    (* Venue symbols: letters, digits and the separators venues use. *)
    let quickcheck_generator =
      Quickcheck.Generator.map
        (String.gen_with_length
           6
           (Quickcheck.Generator.of_list (String.to_list "ABCXYZ019-_/")))
        ~f:of_string
    ;;

    let quickcheck_observer =
      Quickcheck.Observer.unmap String.quickcheck_observer ~f:to_string
    ;;

    let quickcheck_shrinker = Quickcheck.Shrinker.empty ()
  end
end

include Exchange_core.Symbol
include Bin
