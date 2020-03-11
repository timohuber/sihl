module Async = Sihl.Core.Async;
module Layout = ClientLayout;

[@decco]
type t = {token: string};

let login = (setError, ~email, ~password) => {
  let email = email->Belt.Option.getWithDefault("");
  let password = password->Belt.Option.getWithDefault("");
  Fetch.fetch(
    ClientConfig.baseUrl()
    ++ "/users/login?email="
    ++ email
    ++ "&password="
    ++ password,
  )
  ->ClientUtils.handleResponse(
      response => {
        switch (t_decode(response)) {
        | Belt.Result.Ok({token}) =>
          ClientUtils.Token.set(token);
          Async.async(ReasonReactRouter.push("/app/boards/"));
        | Belt.Result.Error(error) =>
          Async.async(
            setError(_ => Some(Sihl.Core.Error.Decco.stringify(error))),
          )
        }
      },
      msg => Async.async(setError(_ => Some("Failed to login: " ++ msg))),
    );
};

[@react.component]
let make = () => {
  let (email, setEmail) = React.useState(() => None);
  let (password, setPassword) = React.useState(() => None);
  let canSubmit =
    switch (email, password) {
    | (Some(_), Some(_)) => true
    | _ => false
    };
  let (_, setError) = React.useContext(ClientContextProvider.Error.context);

  <Layout>
    <div className="columns">
      <div className="column is-one-quarter" />
      <div className="column is-two-quarters">
        <h2 className="title is-2"> {React.string("Login")} </h2>
        <div className="field">
          <label className="label"> {React.string("Email address")} </label>
          <div className="control has-icons-left">
            <input
              onChange={event => {
                let email = ClientUtils.wrapFormValue(event);
                setEmail(_ => email);
              }}
              value={email->Belt.Option.getWithDefault("")}
              className="input"
              name="email"
              type_="email"
              placeholder=""
            />
            <span className="icon is-small is-left">
              <i className="fas fa-envelope" />
            </span>
          </div>
        </div>
        <div className="field">
          <label className="label"> {React.string("Password")} </label>
          <div className="control has-icons-left">
            <input
              onChange={event => {
                let password = ClientUtils.wrapFormValue(event);
                setPassword(_ => password);
              }}
              value={password->Belt.Option.getWithDefault("")}
              className="input"
              name="password"
              type_="password"
              placeholder=""
            />
            <span className="icon is-small is-left">
              <i className="fas fa-lock" />
            </span>
          </div>
        </div>
        <div className="field is-grouped">
          <div className="control">
            <button
              className="button is-link"
              disabled={!canSubmit}
              onClick={_ => {
                let _ = login(setError, ~email, ~password);
                ();
              }}>
              {React.string("Login")}
            </button>
          </div>
        </div>
      </div>
      <div className="column is-one-quarter" />
    </div>
  </Layout>;
};
