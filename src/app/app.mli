module Sig = App_sig

val kernel_services : Core.Container.binding list

val start : (module Sig.APP) -> unit
