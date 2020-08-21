module type SERVICE = sig
  include Core_container.SERVICE

  val register_config : Core_ctx.t -> Config_core.Config.t -> unit Lwt.t
end
