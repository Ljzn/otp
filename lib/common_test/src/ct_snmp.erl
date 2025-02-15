%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2004-2021. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

-module(ct_snmp).

-include("snmp_types.hrl").
-include("inet.hrl").
-include("ct.hrl").

%%% API
-export([start/2, start/3, stop/1, get_values/3, get_next_values/3, set_values/4, 
	 set_info/1, register_users/2, register_agents/2, register_usm_users/2,
	 unregister_users/1, unregister_users/2, unregister_agents/1,
	 unregister_agents/2, unregister_usm_users/1, unregister_usm_users/2,
	 load_mibs/1, unload_mibs/1]).

-type agent_config() :: {Item :: term(), Value :: term()}.
-type agent_ip() :: ip().
-type agent_name() :: atom().
-type agent_port() :: integer().
-type call_back_module() :: atom().
-type error_index() :: integer().
-type error_status() :: noError | atom().
-type ip() :: string() | {integer(), integer(), integer(), integer()}.
-type manager_ip() :: ip().
-type oid() :: [byte()].
-type oids() :: [oid()].
-type rel_path() :: string().
-type sec_type() :: none | minimum | semi.
-type snmp_app_agent_params() :: term().
-type snmp_app_manager_params() :: term().
-type snmpreply() :: {error_status(), error_index(), varbinds()}.
-type user_data() :: term().
-type user_name() :: atom().
-type usm_config() :: {Item :: term(), Value :: term()}.
-type usm_user_name() :: string().
-type value_type() :: o | i | u | g | s.
-type var_and_val() :: {oid(), value_type(), term()}.
-type varbind() :: term().
-type varbinds() :: [varbind()].
-type varsandvals() :: [var_and_val()].

-export_type([agent_config/0, agent_ip/0, agent_name/0, agent_port/0,
              call_back_module/0, error_index/0, error_status/0, ip/0,
              manager_ip/0, oid/0, oids/0, rel_path/0, sec_type/0,
              snmp_app_agent_params/0, snmp_app_manager_params/0, snmpreply/0,
              user_data/0, user_name/0, usm_config/0, usm_user_name/0,
              value_type/0, var_and_val/0, varbind/0, varbinds/0, varsandvals/0]).

%% Manager values
-define(CT_SNMP_LOG_FILE, "ct_snmp_set.log").
-define(MGR_PORT, 5000).
-define(MAX_MSG_SIZE, 484).
-define(ENGINE_ID, "mgrEngine").

%% Agent values
-define(AGENT_ENGINE_ID, "agentEngine").
-define(TRAP_UDP, 5000). 
-define(AGENT_UDP, 4000).
-define(CONF_FILE_VER, [v2]).
-define(AGENT_MAX_MSG_SIZE, 484).
-define(AGENT_NOTIFY_TYPE, trap).
-define(AGENT_SEC_TYPE, none).
-define(AGENT_PASSWD, "").
%%%=========================================================================
%%%  API
%%%=========================================================================

start(Config, MgrAgentConfName) ->
    start(Config, MgrAgentConfName, undefined).

start(Config, MgrAgentConfName, SnmpAppConfName) ->
    StartManager= ct:get_config({MgrAgentConfName, start_manager}, true),
    StartAgent = ct:get_config({MgrAgentConfName, start_agent}, false),
   
    SysName = ct:get_config({MgrAgentConfName, agent_sysname}, "ct_test"),
    {ok, HostName} = inet:gethostname(),
    {ok, Addr} = inet:getaddr(HostName, inet),
    IP = tuple_to_list(Addr),
    AgentManagerIP = ct:get_config({MgrAgentConfName, agent_manager_ip}, IP),
    
    prepare_snmp_env(),
    setup_agent(StartAgent, MgrAgentConfName, SnmpAppConfName, 
		Config, SysName, AgentManagerIP, IP),
    setup_manager(StartManager, MgrAgentConfName, SnmpAppConfName, 
		  Config, AgentManagerIP),
    ok = start_application(snmp),

    manager_register(StartManager, MgrAgentConfName).

start_application(App) ->
    case application:start(App) of
        {error, {already_started, App}} ->
            ok;
        Else ->
            Else
    end.
 
stop(Config) ->
    PrivDir = ?config(priv_dir, Config),
    ok = application:stop(snmp),
    ok = application:stop(mnesia),
    MgrDir =  filename:join(PrivDir,"mgr"),
    ConfDir = filename:join(PrivDir, "conf"),
    DbDir = filename:join(PrivDir,"db"),
    catch del_dir(MgrDir),
    catch del_dir(ConfDir),
    catch del_dir(DbDir).
    
    
get_values(Agent, Oids, MgrAgentConfName) ->
    [Uid | _] = agent_conf(Agent, MgrAgentConfName),
    {ok, SnmpReply, _} = snmpm:sync_get2(Uid, target_name(Agent), Oids),
    SnmpReply.

get_next_values(Agent, Oids, MgrAgentConfName) ->
    [Uid | _] = agent_conf(Agent, MgrAgentConfName),
    {ok, SnmpReply, _} = snmpm:sync_get_next2(Uid, target_name(Agent), Oids),
    SnmpReply.

set_values(Agent, VarsAndVals, MgrAgentConfName, Config) ->
    PrivDir = ?config(priv_dir, Config),
    [Uid | _] = agent_conf(Agent, MgrAgentConfName),
    Oids = lists:map(fun({Oid, _, _}) -> Oid end, VarsAndVals),
    TargetName = target_name(Agent),
    {ok, SnmpGetReply, _} = snmpm:sync_get2(Uid, TargetName, Oids),
    {ok, SnmpSetReply, _} = snmpm:sync_set2(Uid, TargetName, VarsAndVals),
    case SnmpSetReply of
	{noError, 0, _} when PrivDir /= false ->
	    log(PrivDir, Agent, SnmpGetReply, VarsAndVals);
	_ ->
	    set_failed_or_user_did_not_want_to_log
    end,
    SnmpSetReply.

set_info(Config) ->
    PrivDir = ?config(priv_dir, Config),
    SetLogFile = filename:join(PrivDir, ?CT_SNMP_LOG_FILE),
    case file:consult(SetLogFile) of
	{ok, SetInfo} ->
	    ok = delete_file(SetLogFile),
	    lists:reverse(SetInfo);
	_ ->
	    []
    end.

register_users(MgrAgentConfName, Users) ->
    case setup_users(Users) of
	ok ->
	    SnmpVals = ct:get_config(MgrAgentConfName),
	    OldUsers = ct:get_config({MgrAgentConfName,users},[]),
	    NewSnmpVals = lists:keystore(users, 1, SnmpVals,
					 {users, Users ++ OldUsers}),
	    ct_config:update_config(MgrAgentConfName, NewSnmpVals),
	    ok;
	Error ->
	    Error
    end.

register_agents(MgrAgentConfName, ManagedAgents) ->
    case setup_managed_agents(MgrAgentConfName,ManagedAgents) of
	ok ->
	    SnmpVals = ct:get_config(MgrAgentConfName),
	    OldAgents = ct:get_config({MgrAgentConfName,managed_agents},[]),
	    NewSnmpVals = lists:keystore(managed_agents, 1, SnmpVals,
					 {managed_agents,
					  ManagedAgents ++ OldAgents}),
	    ct_config:update_config(MgrAgentConfName, NewSnmpVals),
	    ok;
	Error ->
	    Error
    end.

register_usm_users(MgrAgentConfName, UsmUsers) ->
    EngineID = ct:get_config({MgrAgentConfName, engine_id}, ?ENGINE_ID),
    case setup_usm_users(UsmUsers, EngineID) of
	ok ->
	    SnmpVals = ct:get_config(MgrAgentConfName),
	    OldUsmUsers = ct:get_config({MgrAgentConfName,usm_users},[]),
	    NewSnmpVals = lists:keystore(usm_users, 1, SnmpVals,
					 {usm_users, UsmUsers ++ OldUsmUsers}),
	    ct_config:update_config(MgrAgentConfName, NewSnmpVals),
	    ok;
	Error ->
	    Error
    end.

unregister_users(MgrAgentConfName) ->
    Users = [Id || {Id,_} <- ct:get_config({MgrAgentConfName, users},[])],
    unregister_users(MgrAgentConfName,Users).

unregister_users(MgrAgentConfName,Users) ->
    takedown_users(Users),
    SnmpVals = ct:get_config(MgrAgentConfName),
    AllUsers = ct:get_config({MgrAgentConfName, users},[]),
    RemainingUsers = lists:filter(fun({Id,_}) ->
					  not lists:member(Id,Users)
				  end,
				  AllUsers),
    NewSnmpVals = lists:keyreplace(users, 1, SnmpVals, {users,RemainingUsers}),
    ct_config:update_config(MgrAgentConfName, NewSnmpVals),
    ok.

unregister_agents(MgrAgentConfName) ->    
    ManagedAgents =  [AgentName ||
			 {AgentName, _} <-
			     ct:get_config({MgrAgentConfName,managed_agents},[])],
    unregister_agents(MgrAgentConfName,ManagedAgents).

unregister_agents(MgrAgentConfName,ManagedAgents) ->
    takedown_managed_agents(MgrAgentConfName, ManagedAgents),
    SnmpVals = ct:get_config(MgrAgentConfName),
    AllAgents = ct:get_config({MgrAgentConfName,managed_agents},[]),
    RemainingAgents = lists:filter(fun({Name,_}) ->
					  not lists:member(Name,ManagedAgents)
				   end,
				   AllAgents),
    NewSnmpVals = lists:keyreplace(managed_agents, 1, SnmpVals,
				   {managed_agents,RemainingAgents}),
    ct_config:update_config(MgrAgentConfName, NewSnmpVals),
    ok.

unregister_usm_users(MgrAgentConfName) ->
    UsmUsers = [Id || {Id,_} <- ct:get_config({MgrAgentConfName, usm_users},[])],
    unregister_usm_users(MgrAgentConfName,UsmUsers).

unregister_usm_users(MgrAgentConfName,UsmUsers) ->
    EngineID = ct:get_config({MgrAgentConfName, engine_id}, ?ENGINE_ID),
    takedown_usm_users(UsmUsers,EngineID),
    SnmpVals = ct:get_config(MgrAgentConfName),
    AllUsmUsers = ct:get_config({MgrAgentConfName, usm_users},[]),
    RemainingUsmUsers = lists:filter(fun({Id,_}) ->
					     not lists:member(Id,UsmUsers)
				     end,
				     AllUsmUsers),
    NewSnmpVals = lists:keyreplace(usm_users, 1, SnmpVals,
				   {usm_users,RemainingUsmUsers}),
    ct_config:update_config(MgrAgentConfName, NewSnmpVals),
    ok.

load_mibs(Mibs) ->       
    snmpa:load_mibs(snmp_master_agent, Mibs).
 
unload_mibs(Mibs) ->
    snmpa:unload_mibs(snmp_master_agent, Mibs).

%%%========================================================================
%%% Internal functions
%%%========================================================================
prepare_snmp_env() ->
    %% To make sure application:set_env is not overwritten by any
    %% app-file settings.
    _ = application:load(snmp),
    
    %% Fix for older versions of snmp where there are some
    %% inappropriate default values for always starting an 
    %% agent.
    application:unset_env(snmp, agent).
%%%---------------------------------------------------------------------------
setup_manager(false, _, _, _, _) ->
    ok;
setup_manager(true, MgrConfName, SnmpConfName, Config, IP) ->    
    PrivDir = ?config(priv_dir, Config),
    MaxMsgSize = ct:get_config({MgrConfName,max_msg_size}, ?MAX_MSG_SIZE),
    Port = ct:get_config({MgrConfName,mgr_port}, ?MGR_PORT),
    EngineID = ct:get_config({MgrConfName,engine_id}, ?ENGINE_ID),
    MgrDir =  filename:join(PrivDir,"mgr"),
    %%% Users, Agents and Usms are in test suites register after the
    %%% snmp application is started.
    Users = [],
    Agents = [],
    Usms = [],
    ok = make_dir(MgrDir),
   
    snmp_config:write_manager_snmp_files(MgrDir, IP, Port, MaxMsgSize, 
					 EngineID, Users, Agents, Usms),
    SnmpEnv = merge_snmp_conf([{config, [{dir, MgrDir},{db_dir, MgrDir},
					 {verbosity, trace}]},
			       {server, [{verbosity, trace}]},
			       {net_if, [{verbosity, trace}]},
			       {versions, [v1, v2, v3]}],
			      ct:get_config({SnmpConfName,manager})),
    application:set_env(snmp, manager, SnmpEnv).
%%%---------------------------------------------------------------------------
setup_agent(false,_, _, _, _, _, _) ->
    ok;
setup_agent(true, AgentConfName, SnmpConfName, 
	    Config, SysName, ManagerIP, AgentIP) ->
    ok = start_application(mnesia),
    PrivDir = ?config(priv_dir, Config),
    Vsns = ct:get_config({AgentConfName, agent_vsns}, ?CONF_FILE_VER),
    TrapUdp = ct:get_config({AgentConfName, agent_trap_udp}, ?TRAP_UDP),
    AgentUdp = ct:get_config({AgentConfName, agent_udp}, ?AGENT_UDP),
    NotifType = ct:get_config({AgentConfName, agent_notify_type},
			      ?AGENT_NOTIFY_TYPE),
    SecType = ct:get_config({AgentConfName, agent_sec_type}, ?AGENT_SEC_TYPE),
    Passwd  = ct:get_config({AgentConfName, agent_passwd}, ?AGENT_PASSWD),
    AgentEngineID = ct:get_config({AgentConfName, agent_engine_id}, 
				  ?AGENT_ENGINE_ID),
    AgentMaxMsgSize = ct:get_config({AgentConfName, agent_max_msg_size},
				    ?MAX_MSG_SIZE),
    
    ConfDir = filename:join(PrivDir, "conf"),
    DbDir = filename:join(PrivDir,"db"),
    ok = make_dir(ConfDir),
    ok = make_dir(DbDir),    
    snmp_config:write_agent_snmp_files(ConfDir, Vsns, ManagerIP, TrapUdp, 
				       AgentIP, AgentUdp, SysName, 
				       NotifType, SecType, Passwd,
				       AgentEngineID, AgentMaxMsgSize),

    override_default_configuration(Config, AgentConfName),
    
    SnmpEnv = merge_snmp_conf([{db_dir, DbDir},
			       {config, [{dir, ConfDir},
					 {verbosity, trace}]},
			       {agent_type, master},
			       {agent_verbosity, trace},
			       {net_if, [{verbosity, trace}]},
			       {versions, Vsns}],
			      ct:get_config({SnmpConfName,agent})),
    application:set_env(snmp, agent, SnmpEnv).
%%%---------------------------------------------------------------------------
merge_snmp_conf(Defaults, undefined) ->
    Defaults;
merge_snmp_conf([Def={Key,DefList=[P|_]}|DefParams], UserParams) when is_tuple(P) ->
    case lists:keysearch(Key, 1, UserParams) of
	false ->
	    [Def | merge_snmp_conf(DefParams, UserParams)];
	{value,{Key,UserList}} ->
	    DefList1 = [{SubKey,Val} || {SubKey,Val} <- DefList, 
					lists:keysearch(SubKey, 1, UserList) == false],
	    [{Key,DefList1++UserList} | merge_snmp_conf(DefParams, 
							lists:keydelete(Key, 1, UserParams))]
    end;
merge_snmp_conf([Def={Key,_}|DefParams], UserParams) ->
    case lists:keysearch(Key, 1, UserParams) of
	false ->
	    [Def | merge_snmp_conf(DefParams, UserParams)];
	{value,_} ->
	    merge_snmp_conf(DefParams, UserParams)
    end;
merge_snmp_conf([], UserParams) ->
    UserParams.
			      

%%%---------------------------------------------------------------------------
manager_register(false, _) ->
    ok;
manager_register(true, MgrAgentConfName) ->
    Agents = ct:get_config({MgrAgentConfName, managed_agents}, []),
    Users = ct:get_config({MgrAgentConfName, users}, []),
    UsmUsers = ct:get_config({MgrAgentConfName, usm_users}, []),
    EngineID = ct:get_config({MgrAgentConfName, engine_id}, ?ENGINE_ID),

    setup_usm_users(UsmUsers, EngineID),
    setup_users(Users),
    setup_managed_agents(MgrAgentConfName,Agents).

%%%---------------------------------------------------------------------------
setup_users(Users) ->
    while_ok(fun({Id, [Module, Data]}) ->
		     snmpm:register_user(Id, Module, Data)
	     end, Users).
%%%---------------------------------------------------------------------------   
setup_managed_agents(AgentConfName,Agents) ->
    Fun =
	fun({AgentName, [Uid, AgentIp, AgentUdpPort, AgentConf0]}) ->
		NewAgentIp = case AgentIp of
				 IpTuple when is_tuple(IpTuple) ->
				     IpTuple;
				 HostName when is_list(HostName) ->
				     {ok,Hostent} = inet:gethostbyname(HostName),
				     [IpTuple|_] = Hostent#hostent.h_addr_list,
				     IpTuple
			     end,
		AgentConf =
		    case lists:keymember(engine_id,1,AgentConf0) of
			true ->
			    AgentConf0;
			false ->
			    DefaultEngineID =
				ct:get_config({AgentConfName,agent_engine_id},
					      ?AGENT_ENGINE_ID),
			    [{engine_id,DefaultEngineID}|AgentConf0]
		    end,
		snmpm:register_agent(Uid, target_name(AgentName),
				     [{address,NewAgentIp},{port,AgentUdpPort} |
				      AgentConf])
	end,
    while_ok(Fun,Agents).
%%%---------------------------------------------------------------------------
setup_usm_users(UsmUsers, EngineID)->
    while_ok(fun({UsmUser, Conf}) ->
		     snmpm:register_usm_user(EngineID, UsmUser, Conf)
	     end, UsmUsers).
%%%---------------------------------------------------------------------------
takedown_users(Users) ->
     lists:foreach(fun(Id) ->
			  snmpm:unregister_user(Id)
		   end, Users).
%%%---------------------------------------------------------------------------
takedown_managed_agents(MgrAgentConfName,ManagedAgents) ->
    lists:foreach(fun(AgentName) ->
			  [Uid | _] = agent_conf(AgentName, MgrAgentConfName),
			  snmpm:unregister_agent(Uid, target_name(AgentName))
		  end, ManagedAgents).
%%%---------------------------------------------------------------------------
takedown_usm_users(UsmUsers, EngineID) ->
     lists:foreach(fun(Id) ->
			  snmpm:unregister_usm_user(EngineID, Id)
		   end, UsmUsers).
%%%---------------------------------------------------------------------------  
log(PrivDir, Agent, {_, _, Varbinds}, NewVarsAndVals) ->

    Fun = fun(#varbind{oid = Oid, variabletype = Type, value = Value}) ->
		  {Oid, Type, Value} 
	  end,
    OldVarsAndVals = lists:map(Fun, Varbinds),
    
    File = filename:join(PrivDir, ?CT_SNMP_LOG_FILE),
    {ok, Fd} = file:open(File, [write, append]),
    io:format(Fd, "~p.~n", [{Agent, OldVarsAndVals, NewVarsAndVals}]),
    ok = file:close(Fd),
    ok.
%%%---------------------------------------------------------------------------
del_dir(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    FullPathFiles = lists:map(fun(File) -> filename:join(Dir, File) end,
			      Files),
    lists:foreach(fun file:delete/1, FullPathFiles), 
    ok = delete_dir(Dir),
    ok.
%%%---------------------------------------------------------------------------
agent_conf(Agent, MgrAgentConfName) ->
    Agents = ct:get_config({MgrAgentConfName, managed_agents}),
    case lists:keysearch(Agent, 1, Agents) of
	{value, {Agent, AgentConf}} ->
	    AgentConf;
	_ ->
	    exit({error, {unknown_agent, Agent, Agents}})
    end.
%%%---------------------------------------------------------------------------
override_default_configuration(Config, MgrAgentConfName) ->
    override_contexts(Config,
		      ct:get_config({MgrAgentConfName, agent_contexts}, undefined)),
    override_community(Config,
		       ct:get_config({MgrAgentConfName, agent_community}, undefined)),
    override_sysinfo(Config,
		     ct:get_config({MgrAgentConfName, agent_sysinfo}, undefined)),
    override_vacm(Config,
		  ct:get_config({MgrAgentConfName, agent_vacm}, undefined)),
    override_usm(Config,
		 ct:get_config({MgrAgentConfName, agent_usm}, undefined)),
    override_notify(Config,
		    ct:get_config({MgrAgentConfName, agent_notify_def}, undefined)),
    override_target_address(Config,
			    ct:get_config({MgrAgentConfName, 
					   agent_target_address_def}, 
					  undefined)),
    override_target_params(Config, 
			   ct:get_config({MgrAgentConfName, agent_target_param_def},
					 undefined)).

%%%---------------------------------------------------------------------------
override_contexts(_, undefined) ->
    ok;

override_contexts(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, ContextInfo} = file:consult(FullPathFile),
    override_contexts(Config, ContextInfo);

override_contexts(Config, Contexts) ->
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"context.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_context_config(Dir, "", Contexts).
		
%%%---------------------------------------------------------------------------
override_sysinfo(_, undefined) ->
    ok;

override_sysinfo(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, SysInfo} = file:consult(FullPathFile),
    override_sysinfo(Config, SysInfo);

override_sysinfo(Config, SysInfo) ->   
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"standard.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_standard_config(Dir, "", SysInfo).

%%%---------------------------------------------------------------------------
override_target_address(_, undefined) ->
    ok;
override_target_address(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, TargetAddressConf} = file:consult(FullPathFile),
    override_target_address(Config, TargetAddressConf);

override_target_address(Config, TargetAddressConf) ->
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"target_addr.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_target_addr_config(Dir, "", TargetAddressConf).


%%%---------------------------------------------------------------------------
override_target_params(_, undefined) ->
    ok;
override_target_params(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, TargetParamsConf} = file:consult(FullPathFile),
    override_target_params(Config, TargetParamsConf);

override_target_params(Config, TargetParamsConf) ->
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"target_params.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_target_params_config(Dir, "", TargetParamsConf).

%%%---------------------------------------------------------------------------
override_notify(_, undefined) ->
    ok;
override_notify(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, NotifyConf} = file:consult(FullPathFile),
    override_notify(Config, NotifyConf);

override_notify(Config, NotifyConf) ->
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"notify.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_notify_config(Dir, "", NotifyConf).

%%%---------------------------------------------------------------------------
override_usm(_, undefined) ->
    ok;
override_usm(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, UsmConf} = file:consult(FullPathFile),
    override_usm(Config, UsmConf);

override_usm(Config, UsmConf) ->
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"usm.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_usm_config(Dir, "", UsmConf).

%%%--------------------------------------------------------------------------
override_community(_, undefined) ->
    ok;
override_community(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, CommunityConf} = file:consult(FullPathFile),
    override_community(Config, CommunityConf);

override_community(Config, CommunityConf) ->
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"community.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_community_config(Dir, "", CommunityConf).
   
%%%---------------------------------------------------------------------------

override_vacm(_, undefined) ->
    ok;
override_vacm(Config, {data_dir_file, File}) ->
    Dir = ?config(data_dir, Config),
    FullPathFile = filename:join(Dir, File),
    {ok, VacmConf} = file:consult(FullPathFile),
    override_vacm(Config, VacmConf);

override_vacm(Config, VacmConf) ->
    Dir = filename:join(?config(priv_dir, Config),"conf"),
    File = filename:join(Dir,"vacm.conf"),
    ok = delete_file(File),
    ok = snmp_config:write_agent_vacm_config(Dir, "", VacmConf).

%%%---------------------------------------------------------------------------

target_name(Agent) ->
    atom_to_list(Agent).

while_ok(Fun,[H|T]) ->
    case Fun(H) of
	ok -> while_ok(Fun,T);
	Error -> Error
    end;
while_ok(_Fun,[]) ->
    ok.

delete_file(FileName) ->
    case file:delete(FileName) of
        {error, enoent} -> ok;
        Else -> Else
    end.

make_dir(Dir) ->
    case file:make_dir(Dir) of
        {error, eexist} -> ok;
        Else -> Else
    end.

delete_dir(Dir) ->
    case file:del_dir(Dir) of
        {error, enoent} -> ok;
        Else -> Else
    end.
