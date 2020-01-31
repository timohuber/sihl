module Request: Sihl.Core.Http.REQUEST = {
  type t = Express.Request.t;

  let params = r => r |> Express.Request.params;
  let param = (key, r) => Js.Dict.get(params(r), key);
  let header = (key, r) => r |> Express.Request.get(key);
  let path = r =>
    r |> Express.Request.path |> Tablecloth.String.split(~on="/");
  let originalUrl = r => r |> Express.Request.originalUrl;
  let jsonBody = r => r |> Express.Request.bodyJSON;

  let authToken = header => {
    Tablecloth.(
      header
      |> StrDict.get(~key="authorization")
      |> Option.map(~f=String.split(~on=" "))
      |> Option.map(~f=List.get_at(~index=1))
    );
  };
};

module Response: Sihl.Core.Http.RESPONSE = {
  type t = {
    header: Js.Dict.t(string),
    bodyJson: option(Js.Json.t),
    bodyBuffer: option(Node.Buffer.t),
    bodyFile: option(string),
    status: int,
  };

  let status = r => r.status;
  let bodyJson = r => r.bodyJson;
  let bodyBuffer = r => r.bodyBuffer;
  let bodyFile = r => r.bodyFile;

  let make =
      (~header=?, ~status=?, ~bodyJson=?, ~bodyBuffer=?, ~bodyFile=?, ()) => {
    Tablecloth.{
      header: header |> Option.withDefault(~default=Js.Dict.empty()),
      bodyJson,
      bodyBuffer,
      bodyFile,
      status: status |> Option.withDefault(~default=200),
    };
  };

  let errorToHttpResponse = error => {
    module Message = Sihl.Core.Http.Message;
    Sihl.Core.Log.error(Sihl.Core.Error.message(error), ());
    switch (error) {
    | `ForbiddenError(message) =>
      make(
        ~status=403,
        ~bodyJson=message |> Message.make |> Message.encode,
        (),
      )
    | `NotFoundError(message) =>
      make(
        ~status=404,
        ~bodyJson=message |> Message.make |> Message.encode,
        (),
      )
    | `AuthenticationError(message) =>
      make(
        ~status=401,
        ~bodyJson=message |> Message.make |> Message.encode,
        (),
      )
    | `ServerError(_) =>
      make(
        ~status=403,
        ~bodyJson=
          "An error occurred, our administrators have been notified."
          |> Message.make
          |> Message.encode,
        (),
      )
    | `ClientError(message) =>
      make(
        ~status=400,
        ~bodyJson=message |> Message.make |> Message.encode,
        (),
      )
    | `AuthorizationError(message) =>
      make(
        ~status=403,
        ~bodyJson=message |> Message.make |> Message.encode,
        (),
      )
    };
  };
};

module Http = Sihl.Core.Http.MakeHttp(Request, Response);

module ExpressAdapter = {
  type expressConfig = {
    limitMb: float,
    compression: bool,
    hidePoweredBy: bool,
    urlEncoded: bool,
  };

  let makeExpressResponse =
      (internal: Response.t, external_: Express.Response.t) => {
    open Sihl.Core.Http;
    open Tablecloth;
    let prepared =
      external_
      |> Express.Response.status(
           internal
           |> Response.status
           |> Express.Response.StatusCode.fromInt
           |> Option.withDefault(
                ~default=Express.Response.StatusCode.BadGateway,
              ),
         );
    switch (
      Response.bodyJson(internal),
      Response.bodyBuffer(internal),
      Response.bodyFile(internal),
    ) {
    | (Some(json), _, _) => Express.Response.sendJson(json, prepared)
    | (_, Some(buffer), _) => Express.Response.sendBuffer(buffer, prepared)
    | (_, _, Some(filepath)) =>
      Express.Response.sendFile(filepath, (), prepared)
    | _ =>
      Express.Response.sendJson(
        Sihl.Core.Http.Message.encode({message: "No body provided"}),
        prepared,
      )
    };
  };

  external makeRequest: Express.Request.t => Request.t = "%identity";

  let toPromise =
      (
        req: Request.t,
        externalResponse: Express.Response.t,
        handler: Http.Handler.t,
      ) => {
    req
    ->handler
    ->Future.map(internal => makeExpressResponse(internal, externalResponse))
    ->FutureJs.toPromise;
  };

  let mountStaticRoute = (app, routePath, localPath) => {
    Express.App.useOnPath(
      app,
      ~path=routePath,
      {
        let options = Express.Static.defaultOptions();
        Express.Static.make(localPath, options) |> Express.Static.asMiddleware;
      },
    );
    app;
  };

  let appConfig =
      (~limitMb=?, ~compression=?, ~hidePoweredBy=?, ~urlEncoded=?, ()) => {
    Tablecloth.{
      limitMb: limitMb |> Option.withDefault(~default=10.0),
      compression: compression |> Option.withDefault(~default=true),
      hidePoweredBy: hidePoweredBy |> Option.withDefault(~default=true),
      urlEncoded: urlEncoded |> Option.withDefault(~default=true),
    };
  };

  [@bs.module]
  external compressionMiddleware: unit => Express.Middleware.t = "compression";

  let newApp = ({limitMb, compression, hidePoweredBy, urlEncoded}) => {
    let app = Express.express();
    Express.App.use(
      app,
      Express.Middleware.json(~limit=Express.ByteLimit.mb(limitMb), ()),
    );
    if (compression) {
      Express.App.use(app, compressionMiddleware());
    };
    if (hidePoweredBy) {
      Express.App.disable(app, ~name="x-powered-by");
    };
    if (urlEncoded) {
      Express.App.use(
        app,
        Express.Middleware.urlencoded(~extended=true, ()),
      );
    };
    app;
  };

  let mountRoutes = (app, routes: list(Http.Route.t)) => {
    let _ =
      Tablecloth.List.map(
        ~f=
          r =>
            switch ((r: Http.Route.t)) {
            | (Http.Route.GET, path, handler) =>
              Express.App.get(
                app,
                ~path,
                Express.PromiseMiddleware.from((_, req, res) =>
                  toPromise(makeRequest(req), res, handler)
                ),
              )
            | (Http.Route.POST, path, handler) =>
              Express.App.post(
                app,
                ~path,
                Express.PromiseMiddleware.from((_, req, res) => {
                  toPromise(makeRequest(req), res, handler)
                }),
              )
            },
        routes,
      );
    app;
  };

  let startApp = (app, ~port) => {
    let onListen = e =>
      switch (e) {
      | exception (Js.Exn.Error(e)) =>
        switch (Js.Exn.message(e)) {
        | Some(message) =>
          Sihl.Core.Log.error("Error in express: " ++ message, ())
        | None => Sihl.Core.Log.error("Error in express", ())
        };
        Node.Process.exit(1);
      | _ => Sihl.Core.Log.info("Listening at port 3000", ())
      };

    Express.App.listen(app, ~port, ~onListen, ());
  };
};
