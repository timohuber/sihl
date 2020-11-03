open Lwt.Syntax
module Http = Sihl_http

module Make (AuthnService : Authn.Sig.SERVICE) (UserService : User.Sig.SERVICE) = struct
  let session () =
    let filter handler req =
      let ctx = Http.Request.to_ctx req in
      match Middleware_session.find_opt req with
      | Some session ->
        let* user = AuthnService.find_user_in_session_opt ctx session in
        (match user with
        | Some user ->
          let req = Middleware_user.set user req in
          handler req
        | None -> handler req)
      | None -> handler req
    in
    Opium_kernel.Rock.Middleware.create ~name:"authn_session" ~filter
  ;;
end
