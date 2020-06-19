module File = struct
  type t = { id : string; filename : string; filesize : int; mime : string }
  [@@deriving fields, yojson, show, eq, make]

  let set_mime mime file = { file with mime }

  let set_filesize filesize file = { file with filesize }

  let set_filename filename file = { file with filename }
end

module StoredFile = struct
  type t = { file : File.t; blob : string }
  [@@deriving fields, yojson, show, eq, make]

  let mime stored_file = File.mime stored_file.file

  let filesize stored_file = File.filesize stored_file.file

  let filename stored_file = File.filename stored_file.file

  let set_mime mime stored_file =
    { stored_file with file = File.set_mime mime stored_file.file }

  let set_filesize size stored_file =
    { stored_file with file = File.set_filesize size stored_file.file }

  let set_filename name stored_file =
    { stored_file with file = File.set_filename name stored_file.file }
end

module type SERVICE = sig
  include Sig.SERVICE

  val get_file :
    Http.Req.t -> id:string -> (StoredFile.t option, string) Lwt_result.t

  val upload_base64 :
    Http.Req.t ->
    file:File.t ->
    base64:string ->
    (StoredFile.t, string) Lwt_result.t

  val update_base64 :
    Http.Req.t ->
    file:StoredFile.t ->
    base64:string ->
    (StoredFile.t, string) Lwt_result.t

  val get_data_base64 :
    Http.Req.t -> file:StoredFile.t -> (string option, string) Lwt_result.t
end

module type REPO = sig
  include Sig.REPO

  val insert_file :
    Core.Db.connection -> file:StoredFile.t -> unit Core.Db.db_result

  val insert_blob :
    Core.Db.connection -> id:string -> blob:string -> unit Core.Db.db_result

  val get_file :
    Core.Db.connection -> id:string -> StoredFile.t option Core.Db.db_result

  val get_blob :
    Core.Db.connection -> id:string -> string option Core.Db.db_result

  val update_file :
    Core.Db.connection -> file:StoredFile.t -> unit Core.Db.db_result

  val update_blob :
    Core.Db.connection -> id:string -> blob:string -> unit Core.Db.db_result
end

let key : (module SERVICE) Core_container.Key.t =
  Core_container.Key.create "storage.service"

module Make (Repo : REPO) : SERVICE = struct
  let get_file req ~id = Repo.get_file ~id |> Core.Db.query_db req

  let upload_base64 req ~file ~base64 =
    let ( let* ) = Lwt_result.bind in
    let blob_id = Core.Id.random () |> Core.Id.to_string in
    let* () =
      Repo.insert_blob ~id:blob_id ~blob:base64 |> Core.Db.query_db req
    in
    let stored_file = StoredFile.make ~file ~blob:blob_id in
    let* () = Repo.insert_file ~file:stored_file |> Core.Db.query_db req in
    Lwt.return @@ Ok stored_file

  let update_base64 req ~file ~base64 =
    let ( let* ) = Lwt_result.bind in
    let blob_id = StoredFile.blob file in
    let* () =
      Repo.update_blob ~id:blob_id ~blob:base64 |> Core.Db.query_db req
    in
    let* () = Repo.update_file ~file |> Core.Db.query_db req in
    Lwt.return @@ Ok file

  let get_data_base64 req ~file =
    let blob_id = StoredFile.blob file in
    Repo.get_blob ~id:blob_id |> Core.Db.query_db req

  let provide_repo = Some (Repo.clean, Repo.migrate ())
end

module RepoMariaDb = struct
  let stored_file =
    let encode m =
      let StoredFile.{ file; blob } = m in
      let File.{ id; filename; filesize; mime } = file in
      Ok (id, (filename, (filesize, (mime, blob))))
    in
    let decode (id, (filename, (filesize, (mime, blob)))) =
      (* Logs.err (fun m -> m "Got bytes %s" id);
       * let msg = Printf.sprintf "Invalid id provided %s" id in
       * let id =
       *   id |> Uuidm.of_bytes |> Option.to_result ~none:msg
       *   |> Base.Result.ok_or_failwith |> Uuidm.to_string
       * in
       * Logs.err (fun m -> m "Converted to id %s" id); *)
      let id = Repo.hex_to_uuid id in
      let file = File.make ~id ~filename ~filesize ~mime in
      Ok (StoredFile.make ~file ~blob)
    in
    Caqti_type.(
      custom ~encode ~decode
        Caqti_type.(tup2 string (tup2 string (tup2 int (tup2 string string)))))

  let insert_file connection ~file =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.exec stored_file
        {sql|
INSERT INTO storage_handles (
  uuid,
  filename,
  filesize,
  mime,
  asset_blob
) VALUES (
  UNHEX(REPLACE(?, '-', '')),
  ?,
  ?,
  ?,
  UNHEX(REPLACE(?, '-', ''))
)
|sql}
    in
    Connection.exec request file

  let update_file connection ~file =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.exec stored_file
        {sql|
UPDATE storage_handles SET
  filename = $2,
  filesize = $3,
  mime = $4,
  asset_blob = UNHEX(REPLACE($5, '-', ''))
WHERE
  storage_handles.uuid = UNHEX(REPLACE($1, '-', ''))
|sql}
    in
    Connection.exec request file

  let get_file connection ~id =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.find_opt Caqti_type.string stored_file
        {sql|
SELECT
  HEX(uuid),
  filename,
  filesize,
  mime,
  HEX(asset_blob)
FROM storage_handles
WHERE storage_handles.uuid = UNHEX(REPLACE(?, '-', ''))
|sql}
    in
    Connection.find_opt request id

  let get_blob connection ~id =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.find_opt Caqti_type.string Caqti_type.string
        {sql|
SELECT
  asset_data
FROM storage_blobs
WHERE storage_blobs.uuid = UNHEX(REPLACE(?, '-', ''))
|sql}
    in
    Connection.find_opt request id

  let insert_blob connection ~id ~blob =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.exec
        Caqti_type.(tup2 string string)
        {sql|
INSERT INTO storage_blobs (
  uuid,
  asset_data
) VALUES (
  UNHEX(REPLACE(?, '-', '')),
  ?
)
|sql}
    in
    Connection.exec request (id, blob)

  let update_blob connection ~id ~blob =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.exec
        Caqti_type.(tup2 string string)
        {sql|
UPDATE storage_blobs SET
  asset_data = $2
WHERE
  storage_blobs.uuid = UNHEX(REPLACE($1, '-', ''))
|sql}
    in
    Connection.exec request (id, blob)

  let clean_handles connection =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.exec Caqti_type.unit
        {sql|
           TRUNCATE storage_handles;
          |sql}
    in
    Connection.exec request ()

  let clean_blobs connection =
    let module Connection = (val connection : Caqti_lwt.CONNECTION) in
    let request =
      Caqti_request.exec Caqti_type.unit
        {sql|
           TRUNCATE storage_blobs;
          |sql}
    in
    Connection.exec request ()

  let create_blobs_table =
    Migration.create_step ~label:"create blobs table"
      {sql|
CREATE TABLE IF NOT EXISTS storage_blobs (
  id BIGINT UNSIGNED AUTO_INCREMENT,
  uuid BINARY(16) NOT NULL,
  asset_data MEDIUMBLOB NOT NULL,
  created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT unique_uuid UNIQUE KEY (uuid)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
|sql}

  let create_handles_table =
    Migration.create_step ~label:"create handles table"
      {sql|
CREATE TABLE IF NOT EXISTS storage_handles (
  id BIGINT UNSIGNED AUTO_INCREMENT,
  uuid BINARY(16) NOT NULL,
  filename VARCHAR(255) NOT NULL,
  filesize BIGINT UNSIGNED,
  mime VARCHAR(128) NOT NULL,
  asset_blob BINARY(16) NOT NULL,
  created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT unique_uuid UNIQUE KEY (uuid)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
|sql}

  let migrate () =
    Migration.(
      empty "storage"
      |> add_step create_blobs_table
      |> add_step create_handles_table)

  let clean connection =
    let ( let* ) = Lwt_result.bind in
    let* () = Repo.set_fk_check connection false in
    let* () = clean_handles connection in
    let* () = clean_blobs connection in
    Repo.set_fk_check connection true
end

(** TODO Implement postgres repo **)

module MariaDb = Make (RepoMariaDb)

let mariadb =
  Core.Container.create_binding key (module MariaDb) MariaDb.provide_repo

let upload_base64 req ~file ~base64 =
  match Core.Container.fetch key with
  | Some (module Service : SERVICE) -> Service.upload_base64 req ~file ~base64
  | None ->
      let msg =
        "STORAGE: Could not find storage service, make sure to register one"
      in
      Logs.err (fun m -> m "%s" msg);
      Lwt.return @@ Error msg

let get_file req ~id =
  match Core.Container.fetch key with
  | Some (module Service : SERVICE) -> Service.get_file req ~id
  | None ->
      let msg =
        "STORAGE: Could not find storage service, make sure to register one"
      in
      Logs.err (fun m -> m "%s" msg);
      Lwt.return @@ Error msg

let update_base64 req ~file ~base64 =
  match Core.Container.fetch key with
  | Some (module Service : SERVICE) -> Service.update_base64 req ~file ~base64
  | None ->
      let msg =
        "STORAGE: Could not find storage service, make sure to register one"
      in
      Logs.err (fun m -> m "%s" msg);
      Lwt.return @@ Error msg

let get_data_base64 req ~file =
  match Core.Container.fetch key with
  | Some (module Service : SERVICE) -> Service.get_data_base64 req ~file
  | None ->
      let msg =
        "STORAGE: Could not find storage service, make sure to register one"
      in
      Logs.err (fun m -> m "%s" msg);
      Lwt.return @@ Error msg
