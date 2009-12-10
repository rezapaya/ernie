-module(ernie_server).
-behaviour(gen_server).

%% api
-export([start_link/1, start/1, process/1, kick/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {lsock = undefined,
                pending = queue:new(),
                count = 0,
                map = undefined}).

-record(request, {sock = undefined,
                  info = undefined,
                  action = undefined}).

%%====================================================================
%% API
%%====================================================================

start_link(Args) ->
  gen_server:start_link({global, ?MODULE}, ?MODULE, Args, []).

start(Args) ->
  gen_server:start({global, ?MODULE}, ?MODULE, Args, []).

process(Sock) ->
  gen_server:cast({global, ?MODULE}, {process, Sock}).

kick() ->
  gen_server:cast({global, ?MODULE}, kick).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Port, Configs]) ->
  process_flag(trap_exit, true),
  error_logger:info_msg("~p starting~n", [?MODULE]),
  {ok, LSock} = try_listen(Port, 500),
  spawn(fun() -> loop(LSock) end),
  Map = init_map(Configs),
  io:format("pidmap = ~p~n", [Map]),
  {ok, #state{lsock = LSock, map = Map}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({process, Sock}, State) ->
  Request = #request{sock = Sock},
  State2 = receive_term(Request, State),
  {noreply, State2};
handle_cast(kick, State) ->
  case queue:out(State#state.pending) of
    {{value, Request}, Pending2} ->
      State2 = process_request(Request, Pending2, State),
      {noreply, State2};
    {empty, _Pending} ->
      {noreply, State}
  end;
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(Msg, State) ->
  error_logger:error_msg("Unexpected message: ~p~n", [Msg]),
  {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

extract_mapping(Config) ->
  Id = proplists:get_value(id, Config),
  Mods = proplists:get_value(modules, Config),
  lists:map(fun(X) -> {X, Id} end, Mods).

init_map(Configs) ->
  lists:foldl(fun(X, Acc) -> Acc ++ extract_mapping(X) end, [], Configs).

try_listen(Port, 0) ->
  error_logger:error_msg("Could not listen on port ~p~n", [Port]),
  {error, "Could not listen on port"};
try_listen(Port, Times) ->
  Res = gen_tcp:listen(Port, [binary, {packet, 4}, {active, false}, {reuseaddr, true}]),
  case Res of
    {ok, LSock} ->
      error_logger:info_msg("Listening on port ~p~n", [Port]),
      {ok, LSock};
    {error, Reason} ->
      error_logger:info_msg("Could not listen on port ~p: ~p~n", [Port, Reason]),
      timer:sleep(5000),
      try_listen(Port, Times - 1)
  end.

loop(LSock) ->
  {ok, Sock} = gen_tcp:accept(LSock),
  logger:debug("Accepted socket: ~p~n", [Sock]),
  ernie_server:process(Sock),
  loop(LSock).

process_admin(Sock, reload_handlers, _Args, State) ->
  asset_pool:reload_assets(),
  gen_tcp:send(Sock, term_to_binary({reply, <<"Handlers reloaded.">>})),
  ok = gen_tcp:close(Sock),
  State;
process_admin(Sock, stats, _Args, State) ->
  Count = State#state.count,
  CountString = list_to_binary([<<"connections.total=">>, integer_to_list(Count), <<"\n">>]),
  IdleWorkers = asset_pool:idle_worker_count(),
  IdleWorkersString = list_to_binary([<<"workers.idle=">>, integer_to_list(IdleWorkers), <<"\n">>]),
  QueueLength = queue:len(State#state.pending),
  QueueLengthString = list_to_binary([<<"connections.pending=">>, integer_to_list(QueueLength), <<"\n">>]),
  gen_tcp:send(Sock, term_to_binary({reply, list_to_binary([CountString, IdleWorkersString, QueueLengthString])})),
  ok = gen_tcp:close(Sock),
  State;
process_admin(Sock, _Fun, _Args, State) ->
  gen_tcp:send(Sock, term_to_binary({reply, <<"Admin function not supported.">>})),
  ok = gen_tcp:close(Sock),
  State.

receive_term(Request, State) ->
  Sock = Request#request.sock,
  case gen_tcp:recv(Sock, 0) of
    {ok, BinaryTerm} ->
      logger:debug("Got binary term: ~p~n", [BinaryTerm]),
      Term = binary_to_term(BinaryTerm),
      logger:info("Got term: ~p~n", [Term]),
      case Term of
        {call, '__admin__', Fun, Args} ->
          process_admin(Sock, Fun, Args, State);
        {info, _Command, _Args} ->
          Request2 = Request#request{info = BinaryTerm},
          receive_term(Request2, State);
        _Any ->
          Request2 = Request#request{action = BinaryTerm},
          close_if_cast(Term, Request2),
          Pending2 = queue:in(Request2, State#state.pending),
          ernie_server:kick(),
          State#state{pending = Pending2}
      end;
    {error, closed} ->
      ok = gen_tcp:close(Sock),
      State
  end.

process_request(Request, Pending2, State) ->
  ActionTerm = binary_to_term(Request#request.action),
  {_Type, Mod, _Fun, _Args} = ActionTerm,
  Pid = proplists:get_value(Mod, State#state.map),
  case Pid of
    native ->
      logger:debug("Dispatching to native module~n", []),
      process_native_request(ActionTerm, Request, State);
    ValidPid when is_pid(ValidPid) ->
      logger:debug("Found extern pid ~p~n", [ValidPid]),
      process_extern_request(ValidPid, Request, Pending2, State);
    undefined ->
      Sock = Request#request.sock,
      gen_tcp:send(Sock, term_to_binary({error})),
      ok = gen_tcp:close(Sock),
      State
  end.

close_if_cast(ActionTerm, Request) ->
  case ActionTerm of
    {cast, _Mod, _Fun, _Args} ->
      Sock = Request#request.sock,
      gen_tcp:send(Sock, term_to_binary({noreply})),
      ok = gen_tcp:close(Sock),
      logger:debug("Closed cast.~n", []);
    _Any ->
      ok
  end.

process_native_request(ActionTerm, Request, State) ->
  Count = State#state.count,
  State2 = State#state{count = Count + 1},
  logger:debug("Count = ~p~n", [Count + 1]),
  spawn(fun() -> native:process(ActionTerm, Request) end),
  State2.

process_extern_request(Pid, Request, Pending2, State) ->
  Count = State#state.count,
  State2 = State#state{count = Count + 1},
  logger:debug("Count = ~p~n", [Count + 1]),
  case asset_pool:lease(Pid) of
    {ok, Asset} ->
      logger:debug("Leased asset for pool ~p~n", [Pid]),
      spawn(fun() -> process_now(Pid, Request, Asset) end),
      State2#state{pending = Pending2};
    empty ->
      State
  end.

process_now(Pid, Request, Asset) ->
  try unsafe_process_now(Request, Asset) of
    _AnyResponse -> ok
  catch
    _AnyError -> ok
  after
    asset_pool:return(Pid, Asset),
    ernie_server:kick(),
    gen_tcp:close(Request#request.sock)
  end.

unsafe_process_now(Request, Asset) ->
  BinaryTerm = Request#request.action,
  Term = binary_to_term(BinaryTerm),
  case Term of
    {call, Mod, Fun, Args} ->
      logger:debug("Calling ~p:~p(~p)~n", [Mod, Fun, Args]),
      Sock = Request#request.sock,
      {asset, Port, Token} = Asset,
      logger:debug("Asset: ~p ~p~n", [Port, Token]),
      {ok, Data} = port_wrapper:rpc(Port, BinaryTerm),
      gen_tcp:send(Sock, Data),
      ok = gen_tcp:close(Sock);
    {cast, Mod, Fun, Args} ->
      logger:debug("Casting ~p:~p(~p)~n", [Mod, Fun, Args]),
      {asset, Port, Token} = Asset,
      logger:debug("Asset: ~p ~p~n", [Port, Token]),
      {ok, _Data} = port_wrapper:rpc(Port, BinaryTerm)
  end.