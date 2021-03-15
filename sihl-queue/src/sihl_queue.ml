include Sihl.Contract.Queue

let log_src = Logs.Src.create ("sihl.service." ^ Sihl.Contract.Queue.name)

module Logs = (val Logs.src_log log_src : Logs.LOG)

let create_instance input delay now (job : 'a job) =
  let input = job.encode input in
  let name = job.name in
  let next_run_at =
    match delay with
    | Some delay -> Option.value (Ptime.add_span now delay) ~default:now
    | None -> now
  in
  let max_tries = job.max_tries in
  { id = Uuidm.v `V4 |> Uuidm.to_string
  ; name
  ; input
  ; tries = 0
  ; next_run_at
  ; max_tries
  ; status = Pending
  ; last_error = None
  ; last_error_at = None
  }
;;

let update_next_run_at (retry_delay : Ptime.Span.t) (job_instance : instance) =
  let next_run_at =
    match Ptime.add_span job_instance.next_run_at retry_delay with
    | Some date -> date
    | None -> failwith "Can not determine next run date of job"
  in
  { job_instance with next_run_at }
;;

let incr_tries job_instance =
  { job_instance with tries = job_instance.tries + 1 }
;;

module Make (Repo : Repo.Sig) : Sihl.Contract.Queue.Sig = struct
  let registered_jobs : job' list ref = ref []
  let stop_schedule : (unit -> unit) option ref = ref None

  let dispatch ?delay input (job : 'a job) =
    let open Sihl.Contract.Queue in
    let name = job.name in
    Logs.debug (fun m -> m "Dispatching job %s" name);
    let now = Ptime_clock.now () in
    let job_instance = create_instance input delay now job in
    Repo.enqueue job_instance
  ;;

  let dispatch_all ?delay inputs job =
    let now = Ptime_clock.now () in
    let job_instances =
      List.map (fun input -> create_instance input delay now job) inputs
    in
    Repo.enqueue_all job_instances
  ;;

  let run_job (input : string) (job : job') (job_instance : instance)
      : (unit, string) Result.t Lwt.t
    =
    let open Lwt.Syntax in
    let job_instance_id = job_instance.id in
    let* result =
      Lwt.catch
        (fun () -> job.handle input)
        (fun exn ->
          let exn_string = Printexc.to_string exn in
          Logs.err (fun m ->
              m
                "Exception caught while running job, this is a bug in your job \
                 handler. Don't throw exceptions there, use Result.t instead. \
                 '%s'"
                exn_string);
          Lwt.return @@ Error exn_string)
    in
    match result with
    | Error msg ->
      Logs.err (fun m ->
          m
            "Failure while running job instance %a %s"
            pp_instance
            job_instance
            msg);
      Lwt.catch
        (fun () ->
          let* () = job.failed msg job_instance in
          Lwt.return @@ Error msg)
        (fun exn ->
          let exn_string = Printexc.to_string exn in
          Logs.err (fun m ->
              m
                "Exception caught while cleaning up job, this is a bug in your \
                 job failure handler, make sure to not throw exceptions there \
                 '%s"
                exn_string);
          Lwt.return @@ Error exn_string)
    | Ok () ->
      Logs.debug (fun m ->
          m "Successfully ran job instance '%s'" job_instance_id);
      Lwt.return @@ Ok ()
  ;;

  let update ~job_instance = Repo.update job_instance

  let work_job (job : job') (job_instance : instance) =
    let open Lwt.Syntax in
    let now = Ptime_clock.now () in
    if should_run job_instance now
    then (
      let input_string = job_instance.input in
      let* job_run_status = run_job input_string job job_instance in
      let job_instance =
        job_instance |> incr_tries |> update_next_run_at job.retry_delay
      in
      let job_instance =
        match job_run_status with
        | Error msg ->
          if job_instance.tries >= job.max_tries
          then
            { job_instance with
              status = Failed
            ; last_error = Some msg
            ; last_error_at = Some (Ptime_clock.now ())
            }
          else
            { job_instance with
              last_error = Some msg
            ; last_error_at = Some (Ptime_clock.now ())
            }
        | Ok () -> { job_instance with status = Succeeded }
      in
      update ~job_instance)
    else (
      Logs.debug (fun m ->
          m "Not going to run job instance %a" pp_instance job_instance);
      Lwt.return ())
  ;;

  let work_queue ~jobs =
    let open Lwt.Syntax in
    let* pending_job_instances = Repo.find_workable () in
    let n_job_instances = List.length pending_job_instances in
    if n_job_instances > 0
    then (
      Logs.debug (fun m ->
          m
            "Start working queue of length %d"
            (List.length pending_job_instances));
      let rec loop job_instances jobs =
        match job_instances with
        | [] -> Lwt.return ()
        | (job_instance : instance) :: job_instances ->
          let job =
            List.find_opt
              (fun job -> job.name |> String.equal job_instance.name)
              jobs
          in
          (match job with
          | None -> loop job_instances jobs
          | Some job -> work_job job job_instance)
      in
      let* () = loop pending_job_instances jobs in
      Logs.debug (fun m -> m "Finish working queue");
      Lwt.return ())
    else Lwt.return ()
  ;;

  let register_jobs jobs =
    registered_jobs := List.concat [ !registered_jobs; jobs ];
    Lwt.return ()
  ;;

  let start_queue () =
    Logs.debug (fun m -> m "Start job queue");
    (* This function run every second, the request context gets created here
       with each tick *)
    let scheduled_function () =
      let jobs = !registered_jobs in
      if List.length jobs > 0
      then (
        let job_strings =
          jobs |> List.map (fun job -> job.name) |> String.concat ", "
        in
        Logs.debug (fun m ->
            m "Run job queue with registered jobs: %s" job_strings);
        work_queue ~jobs)
      else (
        Logs.debug (fun m -> m "No jobs found to run, trying again later");
        Lwt.return ())
    in
    let schedule =
      Sihl.Schedule.create
        Sihl.Schedule.every_second
        ~f:scheduled_function
        ~label:"job_queue"
    in
    stop_schedule := Some (Sihl.Schedule.schedule schedule);
    Lwt.return ()
  ;;

  let start () = start_queue () |> Lwt.map ignore

  let stop () =
    registered_jobs := [];
    match !stop_schedule with
    | Some stop_schedule ->
      stop_schedule ();
      Lwt.return ()
    | None ->
      Logs.warn (fun m -> m "Can not stop schedule");
      Lwt.return ()
  ;;

  let lifecycle =
    Sihl.Container.create_lifecycle
      Sihl.Contract.Queue.name
      ~dependencies:(fun () ->
        List.cons Sihl.Schedule.lifecycle Repo.lifecycles)
      ~start
      ~stop
  ;;

  let register ?(jobs = []) () =
    Repo.register_migration ();
    Repo.register_cleaner ();
    registered_jobs := List.concat [ !registered_jobs; jobs ];
    Sihl.Container.Service.create lifecycle
  ;;

  let query () : instance list Lwt.t = Repo.query ()

  let find id : instance Lwt.t =
    let open Lwt.Syntax in
    let* job = Repo.find id in
    match job with
    | Some job -> Lwt.return job
    | None ->
      raise @@ Exception (Format.asprintf "Failed to find with id %s" id)
  ;;

  let update (job : instance) : instance Lwt.t =
    let open Lwt.Syntax in
    let* () = Repo.update job in
    let* updated = Repo.find job.id in
    match updated with
    | Some job -> Lwt.return job
    | None ->
      raise
      @@ Exception (Format.asprintf "Failed to update job %a" pp_instance job)
  ;;

  let requeue (job : instance) : instance Lwt.t =
    let status = Pending in
    let tries = 0 in
    let next_run_at = Ptime_clock.now () in
    let updated = { job with status; tries; next_run_at } in
    update updated
  ;;

  let cancel (job : instance) : instance Lwt.t =
    let status = Cancelled in
    let updated = { job with status } in
    update updated
  ;;

  let router ?middlewares ?back scope =
    Admin_ui.router query find cancel requeue ?back ?middlewares scope
  ;;
end

module InMemory = Make (Repo.InMemory)
module MariaDb = Make (Repo.MariaDb)
module PostgreSql = Make (Repo.PostgreSql)
