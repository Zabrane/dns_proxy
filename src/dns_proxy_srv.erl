%%%-------------------------------------------------------------------
%%% @author  <andelf@gmail.com>
%%% @copyright (C) 2013,
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2013 by  <andelf@gmail.com>
%%%-------------------------------------------------------------------
-module(dns_proxy_srv).

-behaviour(gen_server).

%% API
-export([start_link/0, sync/0, stat/0, delete_domain/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-compile([export_all]).

-define(SERVER, ?MODULE).

-record(state, {sock,table}).

-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("kernel/src/inet_dns.hrl").

-define(DEBUG(Term), io:format("debug: ~p~n", [Term])).
-define(DEBUG(What, Term), io:format("debug ~p: ~p~n", [What, Term])).


-define(DNS_ADDRS, ["8.8.8.8", "8.8.4.4", 	% Google
		    "156.154.70.1", "156.154.71.1", % Dnsadvantage, returns bad
		    "4.2.2.1", "4.2.2.2", "4.2.2.3",
		    "4.2.2.4", "4.2.2.5", "4.2.2.6", %  GTEI DNS (now Verizon)
		    "202.106.196.115", "202.106.0.20" % china unicom
		    ]).

%%-define(DNS_ADDRS, ["202.106.196.115", "202.106.0.20"]).

-define(RESOLVE_TABLE, resolve_table).
-define(FILE_STORE, "./resolve.ets").

-record(dns_record, {domain,
		     type,
		     class,
		     data}).
%% what really store to table
-record(table_record, {dns_record,
		       timestamp,
		       visits=0}).
%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

sync() ->
    gen_server:call(?MODULE, {dump_db}).

stat() ->
    ets:info(?RESOLVE_TABLE).

delete_domain(Domain) ->
    Result = ets:select(?RESOLVE_TABLE,
			ets:fun2ms(fun(R = #table_record{
					      dns_record=#dns_record{domain=D},
					      timestamp=_T}) when D =:= Domain ->
					   R end)),
    lists:map(fun (R) -> ets:delete_object(?RESOLVE_TABLE, R) end,  Result).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    Tid = case ets:file2tab(?FILE_STORE) of
	      {ok, Table} ->
		  io:format("load table ~p from file~n", [Table]),
		  Table;
	      {error, _} ->
		  ets:new(?RESOLVE_TABLE, [set, public, named_table,
					   {keypos, #table_record.dns_record}])
    end,
    case gen_udp:open(53, [binary, {active, true}]) of
	{ok, Sock} ->
	    {ok, #state{sock=Sock,table=Tid}};
	{error, Reason} ->
	    {stop, Reason}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({dump_db}, _From, #state{table=?RESOLVE_TABLE} = State) ->
    Reply = ets:tab2file(?RESOLVE_TABLE, ?FILE_STORE),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({udp, Sock, FromIP, FromPort, Data}, #state{sock=Sock} = State) ->
    %% io:format("got packet from ~p:~p~n", [FromIP, FromPort]),
    spawn(fun() ->
                  handle_dns_data(Data, fun(D) -> gen_udp:send(Sock, FromIP, FromPort, D) end)
          end),
    {noreply, State};
handle_info({udp_error,_Sock,econnreset}, State) ->
    io:format("!!! udp error econnreset ~p~n", [_Sock]),
    {noreply, State};
handle_info(_Info, State) ->
    io:format("unhandled message: ~p~n", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{sock=Sock}) ->
    %% ets:tab2fie(?RESOLVE_TABLE, ?FILE_STORE),
    gen_udp:close(Sock),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_dns_data(Data, SendFunc) ->
    {ok, Packet} = inet_dns:decode(Data),
    handle_dns_packet(Packet, SendFunc).

handle_dns_packet(#dns_rec{header=Header, qdlist=Questions,
			   nslist=_Authorities, arlist=_Resources} = Packet,
		  SendFunc) ->
    handle_dns_header(Header),
    case {Header#dns_header.qr, Header#dns_header.opcode} of
	{true, _} ->
	    %% this is response, ignore
	    handle_dns_header(Header);
	{false, 'query'} ->
	    %% this is a request, query
	    case query_table_by_dns_query(Questions) of
		[] ->
		    query_dns_and_send_response(Packet, SendFunc);
		Cached ->
		    fill_packet_and_send_response(Packet, Cached, SendFunc)
	    end;
	{false, Opcode} ->
	    io:format("EEE unhandled Opcode: ~p~n", [Opcode])
    end,
    %% io:format("packet ~p", [Packet]),
    ok.

fill_packet_and_send_response(Packet=#dns_rec{qdlist=Questions}, Cached, SendFunc) ->
    [#dns_query{domain=Domain,type=Type,class=Class}] = Questions,
    io:format("%%% type:~p ~p class:~p found in cache! items=~p~n",
	      [Type, Domain, Class, length(Cached)]),
    Packet1 = dns_rec_fill_answer(Packet, Cached),
    Packet2 = dns_rec_set_rcode(Packet1, 0), % NoError
    Packet3 = dns_rec_requst_to_response(Packet2),
    SendFunc(inet_dns:encode(Packet3)).

query_dns_and_send_response(Packet=#dns_rec{qdlist=Questions}, SendFunc) ->
    [#dns_query{domain=Domain,type=Type,class=Class}] = Questions,
    case dns_proxy_resolver_sup:query_packet(udp_resolver_pool, Packet) of
	{ok, ReplyPacket} ->
            %% io:format("got dns reply packet ~p~n", [ReplyPacket]),
            ReplyPacket1 = dns_rec_filter_bad_records(ReplyPacket),
            ReplyData = inet_dns:encode(ReplyPacket1),
	    SendFunc(ReplyData),
            io:format("### type:~p ~p class:~p query ok, items=~p .~n",
		      [Type, Domain, Class, length(ReplyPacket#dns_rec.anlist)]),
            %% save to cache
            save_dns_result_to_table(ReplyPacket);
	{error, _Reason} ->
	    io:format("!!! type:~p ~p class:~p query dns error ~p.~n",
		      [Type, Domain, Class, _Reason])
    end.


handle_dns_header(#dns_header{id=_Id,qr=_RespFlag,opcode=_OpCode,rcode=_RCode}) ->
    ok.

handle_dns_questions([#dns_query{domain=Domain,type=Type,class=Class}|Rest]) ->
    io:format("query type:~p ~p class:~p~n", [Type, Domain, Class]),
    handle_dns_questions(Rest);
handle_dns_questions([]) ->
    ok.

handle_dns_answers([#dns_rr{domain=Domain,type=Type,class=Class,
			    cnt=_Count,ttl=_TTL,data=Data,tm=_Time,
			    bm=_,func=_}|Rest]) ->
    io:format("dns record ~p ~p ~p: ~p~n", [Type, Class, Domain, Data]),
    handle_dns_answers(Rest);
handle_dns_answers([]) ->
    ok.

save_dns_result_to_table(Data) when is_binary(Data) ->
    {ok, Packet} = inet_dns:decode(Data),
    save_dns_result_to_table(Packet);
save_dns_result_to_table(Packet) when is_record(Packet, dns_rec) ->
    case Packet#dns_rec.anlist of
	[] ->
	    ok;
	Records ->
	    Records1 = lists:map(fun dns_rr_to_table_obj/1,
				 Records),
	    ets:insert(?RESOLVE_TABLE, Records1)
    end.

query_table_by_dns_query([]) ->
    [];
query_table_by_dns_query(Query) when is_record(Query, dns_query) ->
    #dns_query{domain=Domain,type=Type,class=Class} = Query,
    Result = table_query(Domain, Type, Class),
    fill_cname_query(Result);
query_table_by_dns_query([Query|Rest]=Queries) when is_list(Queries),
						       is_record(Query, dns_query) ->
    %% #dns_query{domain=Domain,type=Type,class=Class} = Query,
    lists:flatten([query_table_by_dns_query(Query),
		   query_table_by_dns_query(Rest)]).


fill_cname_query([]) ->
    [];
fill_cname_query([R|Rest]) ->
    #dns_rr{type=Type, domain=_Domain, data=Data} = R,
    case Type of
	cname ->
	    [R|fill_cname_query(table_query(Data))] ++
		fill_cname_query(Rest);
	_Other ->
	    [R|fill_cname_query(Rest)]
    end.

%% make ttl longer and store to a `bag`
dns_rr_set_ttl(Query, TTL) when is_record(Query, dns_rr), is_integer(TTL) ->
    Query#dns_rr{ttl=TTL}.

%% mac request code is not `0`
dns_rec_set_rcode(Response, RCode) when is_record(Response, dns_rec) ->
    Header = Response#dns_rec.header,
    Response#dns_rec{header=Header#dns_header{rcode=RCode}}.

dns_rec_requst_to_response(Packet) ->
    _OldHeader = Packet#dns_rec.header,
    Packet#dns_rec{header=_OldHeader#dns_header{qr=true}}.

dns_rec_fill_answer(Packet, Answers) when is_list(Answers) ->
    Packet#dns_rec{anlist=Answers}.

dns_rec_filter_bad_records(Response = #dns_rec{anlist=Records}) ->
    Records1 = lists:filter(fun(#dns_rr{type=a, data={202,106,199,_}}) -> % chinaunicom, beijing
                                    false;
                               (#dns_rr{type=a, data={92,242,144,_}}) ->   % Dnsadvantage
                                    false;
                               %% (#dns_rr{type=soa}) -> % discard all soa records
                               %%      false;
                               (#dns_rr{}) ->
                                    true
                            end, Records),
    case Records1 of
        [] ->
            dns_rec_set_rcode(Response#dns_rec{anlist=[]}, 3);
        _ ->
            Response#dns_rec{anlist=Records1}
    end.

table_query(Domain) ->
    %% fun2ms is bad here
    table_query(Domain, a, in).

table_query(Domain, Type, Class) ->
    Result = ets:select(?RESOLVE_TABLE,
			ets:fun2ms(fun(R = #table_record{
					      dns_record=#dns_record{domain=D, type=T, class=C},
					      timestamp=_T})
					 when D =:= Domain, T =:= Type, C =:= Class;
					      D =:= Domain, T =:= cname, C =:= Class ->
					   R#table_record.dns_record end)),
    lists:map(fun dns_record_to_dns_rr/1, Result).

dns_rr_to_table_obj(#dns_rr{domain=Domain, type=Type, class=Class, data=Data}) ->
    %% key
    %%{{Domain, Type, Class}, Data}.
    #table_record{dns_record = #dns_record{domain=Domain, type=Type, class=Class, data=Data},
		  timestamp = dns_utils:timestamp()
		 }.

dns_record_to_dns_rr(#dns_record{domain=Domain, type=Type, class=Class, data=Data}) ->
    #dns_rr{domain = Domain,
	    type = Type,
	    class = Class,
	    ttl = 1024,
	    data = Data}.
