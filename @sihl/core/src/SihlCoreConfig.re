module Env = {
  let get: unit => Js.Json.t = [%raw {| function() { return process.env; } |}];
};

module Db = {
  module Url = {
    [@decco]
    type env = {
      [@decco.key "DATABASE_URL"]
      url: string,
    };

    type t = string;

    let readFromEnv = () => {
      let {url} =
        Env.get()
        |> env_decode
        |> SihlCoreError.Decco.stringifyResult
        |> SihlCoreError.failIfError;
      url;
    };

    let parse = url => {
      switch (
        url |> Js.String.replace("mysql://", "") |> Js.String.split("@")
      ) {
      | [|credentials, hostAndDb|] =>
        switch (Js.String.split(":", credentials)) {
        | [|user, password|] =>
          switch (Js.String.split(":", hostAndDb)) {
          | [|host, portAndDb|] =>
            switch (Js.String.split("/", portAndDb)) {
            | [|port, db|] => Ok((user, password, host, port, db))
            | _ => Error("Invalid database url provided")
            }
          | _ => Error("Invalid database url provided")
          }
        | _ => Error("Invalid database url provided")
        }
      | _ => Error("Invalid database url provided")
      };
    };
  };

  type t = {
    dbUser: string,
    dbHost: string,
    dbName: string,
    dbPassword: string,
    dbPort: string,
    queueLimit: string,
    connectionLimit: string,
  };

  let make = (~user, ~host, ~db, ~password, ~port) => {
    {
      dbUser: user,
      dbHost: host,
      dbName: db,
      dbPassword: password,
      dbPort: port,
      queueLimit: "300",
      connectionLimit: "8",
    };
  };

  let makeFromUrl = (url: Url.t) => {
    url
    ->Url.parse
    ->Belt.Result.map(((user, password, host, port, db)) =>
        make(~user, ~password, ~host, ~port, ~db)
      );
  };
};

let get = _ => "";
