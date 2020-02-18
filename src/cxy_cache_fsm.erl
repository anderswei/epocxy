%%%------------------------------------------------------------------------------
%%% @copyright (c) 2013-2015, DuoMark International, Inc.
%%% @author Jay Nelson <jay@duomark.com>
%%% @reference 2013-2015 Development sponsored by TigerText, Inc. [http://tigertext.com/]
%%% @reference The license is based on the template for Modified BSD from
%%%   <a href="http://opensource.org/licenses/BSD-3-Clause">OSI</a>
%%% @doc
%%%   Generational caching ets owner process. Implemented as a
%%%   supervised FSM to separate management logic from caching logic.
%%%
%%%   As of v0.9.8c the poll frequency for cxy_cache_fsm cannot be less
%%%   than 10 milliseconds.
%%%
%%% @since v0.9.6
%%% @end
%%%------------------------------------------------------------------------------
-module(cxy_cache_fsm).
-author('Jay Nelson <jay@duomark.com>').

-behaviour(gen_statem).

%% API
-export([start_link/2, start_link/3, start_link/4, start_link/5]).

%% gen_statem state functions
-export(['POLL'/3]).

%% gen_statem callbacks
-export([init/1, terminate/3, code_change/4, callback_mode/0, 
         handle_event/3, handle_sync_event/4, handle_info/3]).

-define(SERVER, ?MODULE).

%% Default polling frequency in millis to check for new generation.
-define(POLL_FREQ, 60000).

-record(ecf_state, {
          cache_name                  :: cxy_cache:cache_name(),
          cache_meta_ets = cxy_cache  :: cxy_cache,
          poll_frequency = ?POLL_FREQ :: pos_integer()
         }).


%%%===================================================================
%%% External API
%%%===================================================================

-spec start_link(cxy_cache:cache_name(), module())                      -> {ok, pid()}.
-spec start_link(cxy_cache:cache_name(), module(), pos_integer())       -> {ok, pid()};
                (cxy_cache:cache_name(), module(), cxy_cache:gen_fun()) -> {ok, pid()}.
-spec start_link(cxy_cache:cache_name(), module(), cxy_cache:thresh_type(),
                 pos_integer()) -> {ok, pid()}.
-spec start_link(cxy_cache:cache_name(), module(), cxy_cache:thresh_type(),
                 pos_integer(), pos_integer()) -> {ok, pid()}.

%% start_link is called to reserve a cxy_cache name and specification.
%% The metadata ets table for all caches is created if not already
%% present, so the caller should be a single supervisor to ensure that
%% there is one source for the cache metadata ets ownership. The cache
%% itself is initialized inside the init function so that the new
%% FSM instance is the owner of the internal generation ets tables.

%% No generation creation, so no poll time.
start_link(Cache_Name, Cache_Mod)
    when is_atom(Cache_Name), is_atom(Cache_Mod) ->
    Cache_Name = cxy_cache:reserve(Cache_Name, Cache_Mod),
    gen_statem:start_link(?MODULE, {Cache_Name}, []).

start_link(Cache_Name, Cache_Mod, Gen_Fun)
  when is_atom(Cache_Name), is_atom(Cache_Mod), is_function(Gen_Fun, 3) ->
    Cache_Name = cxy_cache:reserve(Cache_Name, Cache_Mod, Gen_Fun),
    gen_statem:start_link(?MODULE, {Cache_Name}, []).

%% Change frequency that generation function runs...
start_link(Cache_Name, Cache_Mod, Gen_Fun, Poll_Time)
  when is_atom(Cache_Name), is_atom(Cache_Mod), is_function(Gen_Fun, 3),
       is_integer(Poll_Time), Poll_Time >= 10 ->
    Cache_Name = cxy_cache:reserve(Cache_Name, Cache_Mod, Gen_Fun),
    gen_statem:start_link(?MODULE, {Cache_Name, Poll_Time}, []);
%% Use strictly time-based microsecond generational change
%% (but millisecond granularity on FSM polling)...
start_link(Cache_Name, Cache_Mod, time, Gen_Frequency)
  when is_atom(Cache_Name), is_atom(Cache_Mod),
       is_integer(Gen_Frequency), Gen_Frequency >= 10000 ->
    Cache_Name = cxy_cache:reserve(Cache_Name, Cache_Mod, time, Gen_Frequency),
    Poll_Time = round(Gen_Frequency / 1000) + 1,
    gen_statem:start_link(?MODULE, {Cache_Name, Poll_Time}, []);
%% Generational change occurs based on access frequency (using default polling time to check).
start_link(Cache_Name, Cache_Mod, count, Threshold)
  when is_atom(Cache_Name), is_atom(Cache_Mod), is_integer(Threshold), Threshold > 0 ->
    Cache_Name = cxy_cache:reserve(Cache_Name, Cache_Mod, count, Threshold),
    gen_statem:start_link(?MODULE, {Cache_Name}, []);
%% Override default polling with a non-generational cache.
start_link(Cache_Name, Cache_Mod, none, Poll_Time)
  when is_atom(Cache_Name), is_atom(Cache_Mod), is_integer(Poll_Time), Poll_Time >= 10 ->
    Cache_Name = cxy_cache:reserve(Cache_Name, Cache_Mod, none),
    gen_statem:start_link(?MODULE, {Cache_Name, Poll_Time}, []).

%% Generational change occurs based on access frequency (using override polling time to check).
start_link(Cache_Name, Cache_Mod, count, Threshold, Poll_Time)
  when is_atom(Cache_Name), is_atom(Cache_Mod), is_integer(Threshold), Threshold > 0 ->
    Cache_Name = cxy_cache:reserve(Cache_Name, Cache_Mod, count, Threshold),
    gen_statem:start_link({local, ?SERVER}, ?MODULE, {Cache_Name, Poll_Time}, []).


%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

-type state_name() :: 'POLL'.

-spec init({cxy_cache:cache_name()} | {cxy_cache:cache_name(), pos_integer()}) -> {ok, 'POLL', #ecf_state{}}.
-spec terminate   (any(), state_name(), #ecf_state{})        -> ok.
-spec code_change (any(), state_name(), #ecf_state{}, any()) -> {ok, state_name(), #ecf_state{}}.

%% Internal ets table instances containing the generations of cached
%% data will be owned by a corresponding FSM process so that
%% cache instances cannot outlive the parent metadata ets table.
%% The loss of an ets owner automatically means the loss of any owned
%% ets table instances, so all generation creation and rollover needs
%% to be managed and called directly within the FSM process.

init({Cache_Name}) ->
    true = cxy_cache:create(Cache_Name),
    Init_State = #ecf_state{cache_name=Cache_Name},
    init_finish(Init_State);
init({Cache_Name, Poll_Millis}) ->
    true = cxy_cache:create(Cache_Name),
    Init_State = #ecf_state{cache_name=Cache_Name, poll_frequency=Poll_Millis},
    init_finish(Init_State).
callback_mode() -> state_functions.
init_finish(#ecf_state{poll_frequency=Poll_Millis} = Init_State) ->
    erlang:send_after(Poll_Millis, self(), timeout),
    {ok, 'POLL', Init_State}.

terminate   (_Reason, _State_Name, #ecf_state{}) -> ok.
code_change (_OldVsn,  State_Name, #ecf_state{} = State, _Extra) -> {ok, State_Name, State}.

%% The FSM has only the 'POLL' state.
-spec 'POLL'(any(), stop, #ecf_state{}) -> {stop, normal}.
'POLL'(cast, stop, #ecf_state{}) -> {stop, normal};
'POLL'(info, Info, State) -> handle_info(Info, 'POLL', State);
'POLL'({call, From}, Info, State) -> handle_sync_event(Info, From, 'POLL', State);
'POLL'(_Type, Info, State) -> handle_event(Info, 'POLL', State).

%% erlang:send_after is used rather then FSM state timeouts to ensure
%% paced generation checking.
-spec handle_info (any(), state_name(), #ecf_state{})
                  -> {next_state, state_name(), #ecf_state{}}.

handle_info (timeout, State_Name,
             #ecf_state{cache_name=Cache_Name, poll_frequency=Poll_Millis} = State) ->
    _ = cxy_cache:maybe_make_new_generation(Cache_Name),
    erlang:send_after(Poll_Millis, self(), timeout),
    {next_state, State_Name, State};

handle_info (_Info, State_Name, State) ->
    {next_state, State_Name, State}.

%% Handle event and sync_event aren't used
-spec handle_event(any(), state_name(), #ecf_state{})
                  -> {next_state, state_name(), #ecf_state{}}.
-spec handle_sync_event(any(), {pid(), reference()}, state_name(), #ecf_state{})
                       -> {reply, any(), state_name(), #ecf_state{}}.

handle_event      (_Event,        State_Name, State) -> {next_state, State_Name, State}.
handle_sync_event (_Event, _From, State_Name, State) -> {reply, ok,  State_Name, State}.
