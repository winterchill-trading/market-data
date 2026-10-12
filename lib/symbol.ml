open! Core
module Bin = Binable.Of_stringable_without_uuid [@alert "-legacy"] (Exchange_core.Symbol)

module Stable = struct
  module V1 = struct
    include Exchange_core.Symbol
    include Bin
  end
end

include Exchange_core.Symbol
include Bin
