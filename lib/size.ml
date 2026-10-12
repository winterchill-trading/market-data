open! Core

module Bin =
  Binable.Of_binable_without_uuid [@alert "-legacy"]
    (Int)
    (struct
      type t = Exchange_core.Size.t

      let to_binable = Exchange_core.Size.to_units
      let of_binable = Exchange_core.Size.of_units
    end)

module Stable = struct
  module V1 = struct
    include Exchange_core.Size
    include Bin
  end
end

include Exchange_core.Size
include Bin
