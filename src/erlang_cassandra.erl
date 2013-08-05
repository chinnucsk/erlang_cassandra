%%%-------------------------------------------------------------------
%%% @author Mahesh Paolini-Subramanya <mahesh@dieswaytoofast.com>
%%% @copyright (C) 2013 Mahesh Paolini-Subramanya
%%% @doc Thrift based cassandra client
%%%       - Keyspaces map to ServerRef - each keyspace has a
%%%         pool associated with it
%%%       - Only binaries as input. No strings
%%%         
%%% @end
%%%
%%% This source file is subject to the New BSD License. You should have received
%%% a copy of the New BSD license with this software. If not, it can be
%%% retrieved from: http://www.opensource.org/licenses/bsd-license.php
%%%-------------------------------------------------------------------

-module(erlang_cassandra).
-author('Mahesh Paolini-Subramanya <mahesh@dieswaytoofast.com>').

-behaviour(gen_server).

-include("erlang_cassandra.hrl").

%% API
-export([start/0, start/1]).
-export([stop/0, stop/1]).
-export([start_link/1]).
-export([stop_pool/1]).
-export([start_pool/1, start_pool/2, start_pool/3]).
-export([start_cql_pool/1, start_cql_pool/2, start_cql_pool/3]).
-export([registered_pool_name/1]).
-export([get_target/1]).

%% Cassandra Methods
-export([column_parent/1, column_parent/2]).
-export([slice/2, slice/3]).

-export([set_keyspace/1, set_keyspace/2]).
-export([describe_keyspace/1, describe_keyspace/2]).
-export([system_add_keyspace/1, system_add_keyspace/2]).
-export([system_update_keyspace/1, system_update_keyspace/2]).
-export([system_drop_keyspace/1, system_drop_keyspace/2]).

-export([insert/5]).
-export([get/4]).
-export([remove/5]).

-export([system_add_column_family/2]).
-export([system_drop_column_family/2]).
-export([system_update_column_family/2]).
-export([truncate/2]).

-export([add/5]).
-export([remove_counter/4]).

-export([get_slice/5]).
-export([multiget_slice/5]).
-export([get_count/5]).
-export([multiget_count/5]).
-export([get_range_slices/5]).
-export([get_indexed_slices/5]).

-export([execute_cql_query/3]).
-export([prepare_cql_query/3]).
-export([execute_prepared_cql_query/3]).

-export([describe_version/0, describe_version/1]).
-export([describe_snitch/0, describe_snitch/1]).
-export([describe_partitioner/0, describe_partitioner/1]).
-export([describe_keyspaces/0, describe_keyspaces/1]).
-export([describe_cluster_name/0, describe_cluster_name/1]).
-export([describe_ring/1, describe_ring/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(APP, ?MODULE).

-record(state, {
        keyspace                            :: keyspace(),
        set_keyspace                        :: boolean(),
        connection_options                  :: params(),
        connection                          :: connection()}).

%% ------------------------------------------------------------------
%% API
%% ------------------------------------------------------------------

%% @doc Start the application and all its dependencies.
-spec start() -> ok.
start() ->
    reltool_util:application_start(?APP).

%% @doc To start up a 'simple' client
-spec start(params()) -> {ok, pid()}.
start(Options) when is_list(Options) ->
    gen_server:start(?MODULE, [Options], []).

%% @doc Stop the application and all its dependencies.
-spec stop() -> ok.
stop() ->
    reltool_util:application_stop(?APP).

%% @doc Stop this gen_server
-spec stop(server_ref()) -> ok | error().
stop(ServerRef) ->
    gen_server:call(ServerRef, {stop}, ?POOL_TIMEOUT).


%% @doc Used by Poolboy, to start 'unregistered' gen_servers
start_link(ConnectionOptions) ->
    gen_server:start_link(?MODULE, [ConnectionOptions], []).

%% @doc Name used to register the pool server
-spec registered_pool_name(pool_name()) -> registered_pool_name().
registered_pool_name(PoolName) ->
    binary_to_atom(<<?REGISTERED_NAME_PREFIX, PoolName/binary, ".pool">>, utf8).

%% @doc Start a poolboy instance
-spec start_pool(pool_name()) -> supervisor:startchild_ret().
start_pool(PoolName) when is_binary(PoolName) ->
    PoolOptions = application:get_env(erlang_cassandra, pool_options, ?DEFAULT_POOL_OPTIONS),
    ConnectionOptions = application:get_env(erlang_cassandra, connection_options, ?DEFAULT_CONNECTION_OPTIONS),
    start_pool(PoolName, PoolOptions, ConnectionOptions).

%% @doc Start a poolboy instance
-spec start_pool(pool_name(), params()) -> supervisor:startchild_ret().
start_pool(PoolName, PoolOptions) when is_binary(PoolName),
                                       is_list(PoolOptions) ->
    ConnectionOptions = application:get_env(erlang_cassandra, connection_options, ?DEFAULT_CONNECTION_OPTIONS),
    start_pool(PoolName, PoolOptions, ConnectionOptions).

%% @doc Start a poolboy instance with appropriate Pool & Conn settings
-spec start_pool(pool_name(), params(), params()) -> supervisor:startchild_ret().
start_pool(PoolName, PoolOptions, ConnectionOptions) when is_binary(PoolName),
                                                      is_list(PoolOptions),
                                                      is_list(ConnectionOptions) ->
    erlang_cassandra_poolboy_sup:start_pool(PoolName, PoolOptions, ConnectionOptions).


%% @doc Start a pool for cql queries
-spec start_cql_pool(pool_name()) -> supervisor:startchild_ret().
start_cql_pool(PoolName) when is_binary(PoolName) ->
    PoolOptions = application:get_env(erlang_cassandra, pool_options, ?DEFAULT_POOL_OPTIONS),
    ConnectionOptions = application:get_env(erlang_cassandra, connection_options, ?DEFAULT_CONNECTION_OPTIONS),
    start_cql_pool(PoolName, PoolOptions, 
               [{set_keyspace, false} | ConnectionOptions]).

%% @doc Start a poolboy instance
-spec start_cql_pool(pool_name(), params()) -> supervisor:startchild_ret().
start_cql_pool(PoolName, PoolOptions) when is_binary(PoolName),
                                       is_list(PoolOptions) ->
    ConnectionOptions = application:get_env(erlang_cassandra, connection_options, ?DEFAULT_CONNECTION_OPTIONS),
    start_cql_pool(PoolName, PoolOptions, 
               [{set_keyspace, false} | ConnectionOptions]).

%% @doc Start a poolboy instance with appropriate Pool & Conn settings
-spec start_cql_pool(pool_name(), params(), params()) -> supervisor:startchild_ret().
start_cql_pool(PoolName, PoolOptions, ConnectionOptions) when is_binary(PoolName),
                                                      is_list(PoolOptions),
                                                      is_list(ConnectionOptions) ->
    erlang_cassandra_poolboy_sup:start_pool(PoolName, PoolOptions, 
                                            [{set_keyspace, false} | ConnectionOptions]).


%% @doc Stop a poolboy instance
-spec stop_pool(pool_name()) -> ok | error().
stop_pool(PoolName) ->
    erlang_cassandra_poolboy_sup:stop_pool(PoolName).


%% Erlang_Cassandra
column_parent(ColumnFamily) ->
    #columnParent{column_family = ColumnFamily}.

column_parent(SuperColumn, ColumnFamily) ->
    #columnParent{super_column = SuperColumn,
                  column_family = ColumnFamily}.

%% @doc Create a slice_range object for slice queries
%% @end
-spec slice(slice_start(), slice_end(), slice_count()) -> slice_predicate().
slice(Start, End) ->
    slice(Start, End, ?DEFAULT_SLICE_COUNT).
slice(Start, End, Count) ->
    Range = #sliceRange{start = Start, 
                        finish = End, 
                        count = Count},
    #slicePredicate{slice_range = Range,
                    column_names = undefined}.

%% @doc Set the keyspace to be used by the connection
-spec set_keyspace(keyspace()) -> response().
set_keyspace(Keyspace) ->
    set_keyspace(Keyspace, Keyspace).

-spec set_keyspace(server_ref(), keyspace()) -> response().
set_keyspace(ServerRef, Keyspace) ->
    route_call(ServerRef, {set_keyspace, [Keyspace]}, ?POOL_TIMEOUT).

%% @doc Describe the keyspace used by the connection
-spec describe_keyspace(keyspace()) -> response().
describe_keyspace(Keyspace) ->
    describe_keyspace(Keyspace, Keyspace).

-spec describe_keyspace(server_ref(), keyspace()) -> response().
describe_keyspace(ServerRef, Keyspace) ->
    route_call(ServerRef, {describe_keyspace, [Keyspace]}, ?POOL_TIMEOUT).

%% @doc Add a keyspace
-spec system_add_keyspace(keyspace_definition()) -> response().
system_add_keyspace(KeyspaceDefinition) ->
    Keyspace = KeyspaceDefinition#ksDef.name,
    system_add_keyspace(Keyspace, KeyspaceDefinition).

-spec system_add_keyspace(server_ref(), keyspace_definition()) -> response().
system_add_keyspace(ServerRef, KeyspaceDefinition) ->
    route_call(ServerRef, {system_add_keyspace, KeyspaceDefinition}, ?POOL_TIMEOUT).

%% @doc Update a keyspace
-spec system_update_keyspace(keyspace_definition()) -> response().
system_update_keyspace(KeyspaceDefinition) ->
    Keyspace = KeyspaceDefinition#ksDef.name,
    system_update_keyspace(Keyspace, KeyspaceDefinition).

-spec system_update_keyspace(server_ref(), keyspace_definition()) -> response().
system_update_keyspace(ServerRef, KeyspaceDefinition) ->
    route_call(ServerRef, {system_update_keyspace, KeyspaceDefinition}, ?POOL_TIMEOUT).

%% @doc Remove a keyspace
-spec system_drop_keyspace(keyspace()) -> response().
system_drop_keyspace(Keyspace) ->
    system_drop_keyspace(Keyspace, Keyspace).

-spec system_drop_keyspace(server_ref(), keyspace()) -> response().
system_drop_keyspace(ServerRef, Keyspace) ->
    route_call(ServerRef, {system_drop_keyspace, Keyspace}, ?POOL_TIMEOUT).

%% @doc Insert a column
-spec insert(server_ref(), row_key(), column_parent(), column(), consistency_level()) -> response().
insert(ServerRef, RowKey, ColumnParent, Column, ConsistencyLevel) ->
    route_call(ServerRef, {insert, RowKey, ColumnParent, Column, ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Get a column
-spec get(server_ref(), row_key(), column_path(), consistency_level()) -> response().
get(ServerRef, RowKey, ColumnPath, ConsistencyLevel) ->
    route_call(ServerRef, {get, RowKey, ColumnPath, ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Remove data from the row specified by key at the granularity 
%%      specified by column_path, and the given timestamp
-spec remove(server_ref(), row_key(), column_path(), column_timestamp(), 
                           consistency_level()) -> response().
remove(ServerRef, RowKey, ColumnPath, ColumnTimestamp, ConsistencyLevel) ->
    route_call(ServerRef, {remove, RowKey, ColumnPath, ColumnTimestamp, 
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Add a column fmaily
-spec system_add_column_family(server_ref(), column_family_definition()) -> response().
system_add_column_family(ServerRef, ColumnFamilyDefinition) ->
    route_call(ServerRef, {system_add_column_family, ColumnFamilyDefinition}, ?POOL_TIMEOUT).

%% @doc Add a column fmaily
-spec system_drop_column_family(server_ref(), column_family()) -> response().
system_drop_column_family(ServerRef, ColumnFamily) ->
    route_call(ServerRef, {system_drop_column_family, ColumnFamily}, ?POOL_TIMEOUT).

%% @doc Update a column fmaily
-spec system_update_column_family(server_ref(), column_family()) -> response().
system_update_column_family(ServerRef, ColumnFamily) ->
    route_call(ServerRef, {system_update_column_family, ColumnFamily}, ?POOL_TIMEOUT).

%% @doc Remove all rows from a column fmaily
-spec truncate(server_ref(), column_family()) -> response().
truncate(ServerRef, ColumnFamily) ->
    route_call(ServerRef, {truncate, ColumnFamily}, ?POOL_TIMEOUT).

%% @doc Increment a counter column
-spec add(server_ref(), row_key(), column_parent(), counter_column(), consistency_level()) -> response().
add(ServerRef, RowKey, ColumnParent, CounterColumn, ConsistencyLevel) ->
    route_call(ServerRef, {add, RowKey, ColumnParent, CounterColumn,
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Remove a counter
-spec remove_counter(server_ref(), row_key(), column_path(), consistency_level()) -> response().
remove_counter(ServerRef, RowKey, ColumnPath, ConsistencyLevel) ->
    route_call(ServerRef, {remove_counter, RowKey, ColumnPath, ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Get a group of columns based on a slice
-spec get_slice(server_ref(), row_key(), column_parent(), slice_predicate(), consistency_level()) -> response().
get_slice(ServerRef, RowKey, ColumnParent, SlicePredicate, ConsistencyLevel) ->
    route_call(ServerRef, {get_slice, RowKey, ColumnParent, SlicePredicate,
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Get a group of columns based on a slice and a list of rows
-spec multiget_slice(server_ref(), [row_key()], column_parent(), slice_predicate(), consistency_level()) -> response().
multiget_slice(ServerRef, RowKeys, ColumnParent, SlicePredicate, ConsistencyLevel) when is_list(RowKeys) ->
    route_call(ServerRef, {multiget_slice, RowKeys, ColumnParent, SlicePredicate,
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Count columns based on a slice
%%      WARNING: NOT O(1)
-spec get_count(server_ref(), row_key(), column_parent(), slice_predicate(), consistency_level()) -> response().
get_count(ServerRef, RowKey, ColumnParent, SlicePredicate, ConsistencyLevel) ->
    route_call(ServerRef, {get_count, RowKey, ColumnParent, SlicePredicate,
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Count columns based on a slice and a list of rows
%%      WARNING: NOT O(1)
-spec multiget_count(server_ref(), [row_key()], column_parent(), slice_predicate(), consistency_level()) -> response().
multiget_count(ServerRef, RowKeys, ColumnParent, SlicePredicate, ConsistencyLevel) when is_list(RowKeys) ->
    route_call(ServerRef, {multiget_count, RowKeys, ColumnParent, SlicePredicate,
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Get a list of slices for the keys within the specified KeyRange
-spec get_range_slices(server_ref(),  column_parent(), slice_predicate(), key_range(), consistency_level()) -> response().
get_range_slices(ServerRef, ColumnParent, SlicePredicate, KeyRange, ConsistencyLevel) ->
    route_call(ServerRef, {get_range_slices, ColumnParent, SlicePredicate, KeyRange,
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Get a list of slices using IndexRange
-spec get_indexed_slices(server_ref(),  column_parent(), slice_predicate(), key_range(), consistency_level()) -> response().
get_indexed_slices(ServerRef, ColumnParent, IndexClause, SlicePredicate, ConsistencyLevel) ->
    route_call(ServerRef, {get_indexed_slices, ColumnParent, IndexClause, SlicePredicate,
                           ConsistencyLevel}, ?POOL_TIMEOUT).

%% @doc Execute a CQL query
-spec execute_cql_query(pool_name(), cql_query(), compression()) -> response().
execute_cql_query(CqlPool, CqlQuery, Compression) when is_binary(CqlQuery) ->
    route_call(CqlPool, {execute_cql_query, CqlQuery, Compression}, ?POOL_TIMEOUT).

%% @doc Prepare a CQL query
-spec prepare_cql_query(pool_name(), cql_query(), compression()) -> response().
prepare_cql_query(CqlPool, CqlQuery, Compression) when is_binary(CqlQuery) ->
    route_call(CqlPool, {prepare_cql_query, CqlQuery, Compression}, ?POOL_TIMEOUT).

%% @doc Execute a prepared a CQL query
-spec execute_prepared_cql_query(pool_name(), cql_query(), compression()) -> response().
execute_prepared_cql_query(CqlPool, CqlQuery, Compression) when is_binary(CqlQuery) ->
    route_call(CqlPool, {execute_prepared_cql_query, CqlQuery, Compression}, ?POOL_TIMEOUT).

%% @doc Get the Thrift API version
-spec describe_version() -> response().
describe_version() ->
    describe_version(?DEFAULT_POOL_NAME).

%% @doc Get the Thrift API version
-spec describe_version(server_ref()) -> response().
describe_version(ServerRef) ->
    route_call(ServerRef, {describe_version}, ?POOL_TIMEOUT).

%% @doc Get the snitch used for the cluster
-spec describe_snitch() -> response().
describe_snitch() ->
    describe_snitch(?DEFAULT_POOL_NAME).

%% @doc Get the Thrift API snitch
-spec describe_snitch(keyspace()) -> response().
describe_snitch(ServerRef) ->
    route_call(ServerRef, {describe_snitch}, ?POOL_TIMEOUT).

%% @doc Get the partitioner used for the cluster
-spec describe_partitioner() -> response().
describe_partitioner() ->
    describe_partitioner(?DEFAULT_POOL_NAME).

%% @doc Get the Thrift API partitioner
-spec describe_partitioner(keyspace()) -> response().
describe_partitioner(ServerRef) ->
    route_call(ServerRef, {describe_partitioner}, ?POOL_TIMEOUT).

%% @doc Get the cluster_name 
-spec describe_cluster_name() -> response().
describe_cluster_name() ->
    describe_cluster_name(?DEFAULT_POOL_NAME).

%% @doc Get the Thrift API cluster_name
-spec describe_cluster_name(keyspace()) -> response().
describe_cluster_name(ServerRef) ->
    route_call(ServerRef, {describe_cluster_name}, ?POOL_TIMEOUT).


%% @doc Get the list of all the keyspaces
-spec describe_keyspaces() -> response().
describe_keyspaces() ->
    describe_keyspaces(?DEFAULT_POOL_NAME).

%% @doc Get the Thrift API keyspaces
-spec describe_keyspaces(keyspace()) -> response().
describe_keyspaces(ServerRef) ->
    route_call(ServerRef, {describe_keyspaces}, ?POOL_TIMEOUT).

%% @doc Gets the token ring; a map of ranges to host addresses
-spec describe_ring(keyspace()) -> response().
describe_ring(Keyspace) ->
    describe_ring(Keyspace, Keyspace).

-spec describe_ring(server_ref(), keyspace()) -> response().
describe_ring(ServerRef, Keyspace) ->
    route_call(ServerRef, {describe_ring, [Keyspace]}, ?POOL_TIMEOUT).




%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([ConnectionOptions0]) ->
    {Keyspace1, ConnectionOptions2} = 
    case lists:keytake(pool_name, 1, ConnectionOptions0) of
        {value, {pool_name, Keyspace0}, ConnectionOptions1} -> 
            {Keyspace0, ConnectionOptions1};
        false ->
            {?DEFAULT_KEYSPACE, ConnectionOptions0}
    end,
    {SetKeyspace, ConnectionOptions4} = 
    case lists:keytake(set_keyspace, 1, ConnectionOptions2) of
        {value, {set_keyspace, Bool}, ConnectionOptions3} -> 
            {Bool, ConnectionOptions3};
        false ->
            {false, ConnectionOptions2}
    end,
    Connection0 = connection(ConnectionOptions4),
    State0 = #state{keyspace = Keyspace1, 
                    set_keyspace = SetKeyspace,
                    connection_options = ConnectionOptions4,
                    connection = Connection0},
    {Connection1, _Response} = 
    case SetKeyspace of 
        true ->
            % On startup, set the keyspace for this connection
            process_request(Connection0, {set_keyspace, [Keyspace1]}, State0);
        false ->
            {Connection0, ok}
    end,
    {ok, State0#state{connection = Connection1}}.

handle_call({stop}, _From, State) ->
    thrift_client:close(State#state.connection),
    {stop, normal, ok, State};

handle_call(Command, _From, State = #state{connection = Connection0}) ->
    Request = request(Command),
    {Connection1, Response} = process_request(Connection0, Request, State),
    {reply, Response, State#state{connection = Connection1}};

handle_call(_Request, _From, State) ->
    thrift_client:close(State#state.connection),
    {stop, unhandled_call, State}.

handle_cast(_Request, State) ->
    thrift_client:close(State#state.connection),
    {stop, unhandled_info, State}.

handle_info(_Info, State) ->
    thrift_client:close(State#state.connection),
    {stop, unhandled_info, State}.

terminate(_Reason, State) ->
    thrift_client:close(State#state.connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
%% @doc Build a new connection
-spec connection(params()) -> connection().
connection(ConnectionOptions) ->
    ThriftHost = proplists:get_value(thrift_host, ConnectionOptions, ?DEFAULT_THRIFT_HOST),
    ThriftPort = proplists:get_value(thrift_port, ConnectionOptions, ?DEFAULT_THRIFT_PORT),
    ThriftOptions = case lists:keyfind(thrift_options, 1, ConnectionOptions) of
        {thrift_options, Options} -> Options;
        false -> ?DEFAULT_THRIFT_OPTIONS
    end,
    case thrift_client_util:new(ThriftHost, ThriftPort, cassandra_thrift, ThriftOptions) of
        {ok, Connection} -> Connection;
        {error, _Error} -> undefined
    end.

%% @doc Create a Thrift command based on the function and arguments
-spec request(request()) -> request().

request({F}) ->
    % No arguments is actually an empty list
    {F, []};
request({F, A1}) ->
    {F, [A1]};
request({F, A1, A2}) ->
    {F, [A1, A2]};
request({F, A1, A2, A3}) ->
    {F, [A1, A2, A3]};
request({F, A1, A2, A3, A4}) ->
    {F, [A1, A2, A3, A4]};
request({F, A1, A2, A3, A4, A5}) ->
    {F, [A1, A2, A3, A4, A5]};
request({F, A1, A2, A3, A4, A5, A6}) ->
    {F, [A1, A2, A3, A4, A5, A6]};
request({F, A1, A2, A3, A4, A5, A6, A7}) ->
    {F, [A1, A2, A3, A4, A5, A6, A7]};
request({F, A1, A2, A3, A4, A5, A6, A7, A8}) ->
    {F, [A1, A2, A3, A4, A5, A6, A7, A8]}.


%% @doc Process the request over thrift
-spec process_request(connection(), request(), #state{}) -> {connection(), response()}.
process_request(undefined, {Function, Args}, State = #state{connection_options = ConnectionOptions}) ->
    Connection = connection(ConnectionOptions),
    do_request(Connection, {Function, Args}, State#state{connection = Connection});
process_request(Connection, {Function, Args}, State) ->
    do_request(Connection, {Function, Args}, State).

-spec do_request(connection(), request(), #state{}) -> {connection(), response()}.
do_request(Connection, {Function, Args}, _State) ->
    try thrift_client:call(Connection, Function, Args) of
        {Connection1, Response = {ok, _}} ->
            {Connection1, Response};
        {_,  Response = {error, econnrefused}} ->
            {undefined, Response};
        {_,  Response = {error, closed}} ->
            {undefined, Response};
        {Connection1, Response = {error, _}} ->
            {Connection1, Response}
    catch
        Exception:Reason ->
            case {Exception, Reason} of
                {throw, {Connection1, Response = {exception, _}}} ->
                    {Connection1, Response};
                {error, badarg} ->
                    {Connection, {error, badarg}}

            end
    end.

%% @doc Send the request to either poolboy, or the gen_server
-spec route_call(server_ref(), tuple(), timeout()) -> response().
route_call(Keyspace, Command = {_Function}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1, _A2}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1, _A2, _A3}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1, _A2, _A3, _A4}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1, _A2, _A3, _A4, _A5}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1, _A2, _A3, _A4, _A5, _A6}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1, _A2, _A3, _A4, _A5, _A6, _A7}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);
route_call(Keyspace, Command = {_Function, _A1, _A2, _A3, _A4, _A5, _A6, _A7, _A8}, Timeout) when is_binary(Keyspace) ->
    pool_call(Keyspace, Command, Timeout);

% Doubled list because of the Poolboy double routing
route_call(ServerRef, Command = {_Function}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, {Function, [[A1]]}, Timeout) ->
    route_call(ServerRef, {Function, [A1]}, Timeout);
route_call(ServerRef, {Function, [A1]}, Timeout) ->
    route_call(ServerRef, {Function, A1}, Timeout);
route_call(ServerRef, Command = {_Function, _A1}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, Command = {_Function, _A1, _A2}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, Command = {_Function, _A1, _A2, _A3}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, Command = {_Function, _A1, _A2, _A3, _A4}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, Command = {_Function, _A1, _A2, _A3, _A4, _A5}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, Command = {_Function, _A1, _A2, _A3, _A4, _A5, _A6}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, Command = {_Function, _A1, _A2, _A3, _A4, _A5, _A6, _A7}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout);
route_call(ServerRef, Command = {_Function, _A1, _A2, _A3, _A4, _A5, _A6, _A7, _A8}, Timeout) ->
    gen_server:call(get_target(ServerRef), Command, Timeout).

pool_call(PoolName, Command, Timeout) ->
    PoolId = registered_pool_name(PoolName),
    TransactionFun = fun() ->
            poolboy:transaction(PoolId, fun(Worker) ->
                        gen_server:call(Worker, Command, Timeout)
                end) end,
    try
        TransactionFun()
    % If the pool doesnt' exist, the keyspace has not been set before
    catch
        exit:{noproc, _} ->
            start_pool(PoolName),
            TransactionFun()
    end.

    
%% @doc Get the target for the server_ref
-spec get_target(server_ref()) -> target().
get_target(ServerRef) when is_pid(ServerRef) ->
    ServerRef;
get_target(ServerRef) when is_atom(ServerRef) ->
    ServerRef.
