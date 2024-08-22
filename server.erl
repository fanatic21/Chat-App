-module(server).
-behaviour(gen_server).
-compile(export_all).
-include_lib("stdlib/include/qlc.hrl").
% message - type
% type -> personal / broadcast
-record(state,
        {numberOfClients,
         prevMessagesLimit,
         status,
         serverPid,
         onlyAdminStatus,
         offlineMessages}).

% {Sender, Type, ReceiverIfPersonal, Text, {date(), time()}}
-record(message_history, {primary_key, sender, text, date, time}).
-record(offline_messages, {primary_key, receiver, sender, text, date, time}).
-record(user_data, {name, pid, ogPid, isAdmin = 0, isMuted = 0, mutedTill = 0}).

% init record here
start_server(NumberOfClients, PrevMessagesLimit) ->
    mnesia:create_schema([node()]),
    mnesia:start(),
    mnesia:create_table(message_history, [{attributes, record_info(fields, message_history)}]),
    mnesia:create_table(offline_messages, [{attributes, record_info(fields, offline_messages)}]),
    mnesia:create_table(user_data, [{attributes, record_info(fields, user_data)}]),
    % mnesia:stop(),
    State =
        #state{numberOfClients = NumberOfClients,
               prevMessagesLimit = PrevMessagesLimit,
               status = "Default Description",
               serverPid = self(),
               onlyAdminStatus = 0,
               offlineMessages = maps:new()},
    gen_server:start_link({local, ?MODULE}, ?MODULE, [State], []),
    gen_server_started.

init([State]) -> {ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.


handle_call(Request, _, State) ->
    case Request of
        {connect, {Name, ReceivingPid, OgPid}} when State#state.numberOfClients > 0 ->
            Trans = fun() ->
                    qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.name == Name]))
                    end,
                {_ , UserData} = mnesia:transaction(Trans),
               case UserData of
                [] ->   
                    SaveUserData = #user_data{name = Name, pid = ReceivingPid, ogPid = OgPid, isAdmin = 0, isMuted = 0, mutedTill = 0},
                    Trans1 = fun() ->
                                mnesia:write(SaveUserData)
                             end,
                    mnesia:transaction(Trans1),
                    io:format("~s Connected ~n", [Name]),
                    {H, M, S} = time(),
                    {Y, Month, D} = date(),
                    Reply = io_lib:format("Connected ~n[~2..0w/~2..0w/~4..0w  ~2..0w:~2..0w:~2..0w] Current Status : ~s", [D, Month, Y, H, M, S, State#state.status]),
                    send_prev_messages(ReceivingPid, State#state.prevMessagesLimit),
                    JoiningMessage = io_lib:format("~s has joined the chat", [Name]),
                    broadcast({"", "", "", JoiningMessage, {date(), time()}}),
                    send_offline_messages(ReceivingPid, Name),
                    NewState = State#state{numberOfClients = State#state.numberOfClients - 1},
                    {reply, Reply, NewState};
                [_] ->
                    {H, M, S} = time(),
                    {Y, Month, D} = date(),
                    Reply = io_lib:format("[~2..0w/~2..0w/~4..0w  ~2..0w:~2..0w:~2..0w] Error --> User already exists", [D, Month, Y, H, M, S]),
                    {reply, Reply, State}
                end;
            
        {connect, {_, _, _}} when State#state.numberOfClients == 0 ->
            {H, M, S} = time(),
            {Y, Month, D} = date(),
            Reply = io_lib:format("[~2..0w/~2..0w/~4..0w  ~2..0w:~2..0w:~2..0w] Error --> maximum clients reached", [D, Month, Y, H, M, S]),
            {reply, Reply, State};

        {disconnect, {OgPid}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [] ->
                    {reply, ok, State};
                [_] ->
                   [UserData] = IsConnected,
                   {_, Name, ReceivingPid, _, _, _, _} = UserData,
                   OId = {user_data, Name},
                   Trans1 = fun() ->
                        mnesia:delete(OId) %might give error
                        end,
                   mnesia:transaction(Trans1),
                   ReceivingPid ! {update, {date(), time()}, "disconnected"},
                   io:format(Name ++ " disconnected~n"),
                   ExitMessage = Name ++ " has left the chat",
                   broadcast({"", "", "", ExitMessage, {date(), time()}}),
                   NewState = State#state{numberOfClients = 1 + State#state.numberOfClients},
                   {reply, ok, NewState}
            end;

        {message, {OgPid, Type, ReceiverIfPersonal, Text}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [] ->
                    {reply, ok, State};
                [_] ->
                    [UserData] = IsConnected,
                    {_, Sender, _, _, _, _, _} = UserData,
                    case Type of
                        1 -> % private
                            Trans1 = fun() ->
                                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.name == ReceiverIfPersonal]))
                                        end,
                            {_, ReceiverExists} = mnesia:transaction(Trans1),
                           case ReceiverExists of
                                [_] ->
                                  [{_, _, ReceivingPid, _, _, _, _}] = ReceiverExists,
                                  ReceivingPid ! {message,
                                     Sender,
                                     Type,
                                     ReceiverIfPersonal,
                                     Text,
                                     {date(), time()}},
                                     {reply, ok, State};
                                [] ->
                                  {_, _, ReceivingPid, _, _, _, _} = UserData,
                                  ReceivingPid ! {update, {date(), time()}, "Receiver is not connected, will recieve message when connects"},
                                  SaveOfflineMessage = #offline_messages{primary_key = os:system_time(microsecond),
                                                                         receiver = ReceiverIfPersonal,
                                                                         sender = Sender,
                                                                         text = Text,
                                                                         date = date(),
                                                                         time = time()},
                                  Trans2 = fun() -> 
                                            mnesia:write(SaveOfflineMessage)
                                          end,
                                  mnesia:transaction(Trans2),
                                  {reply, ok, State}
                           end;
                        0 -> % broadcast
                           {_, _, _, _, _, IsMuted, MutedTill} = UserData,
                           case IsMuted of
                               1 ->
                                   TimeExpired = MutedTill < os:system_time(second),
                                   case TimeExpired of
                                        true ->
                                            Message = io_lib:format("~s : ~s", [Sender, Text]),
                                            broadcast({Sender, Type, ReceiverIfPersonal, Message, {date(), time()}}),
                                            io:format("~s : ~s~n", [Sender, Text]),
                                            SaveMessage = #message_history{primary_key = os:system_time(microsecond),
                                                                            sender = Sender,
                                                                            text = Text,
                                                                            date = date(),
                                                                            time = time()},
                                            Trans1 = fun() ->
                                                mnesia:write(SaveMessage)
                                            end,
                                            mnesia:transaction(Trans1),
                                            {reply, "ok", State};
                                        false ->
                                            TimeLeft = MutedTill - os:system_time(second),
                                            {H, M, S} = time(),
                                            {Y, Month, D} = date(),
                                            Reply = io_lib:format("[~2..0w/~2..0w/~4..0w  ~2..0w:~2..0w:~2..0w] You're muted till next ~w seconds", [D, Month, Y, H, M, S, TimeLeft]),
                                            {reply, Reply, State}
                                    end;
                                0 ->
                                    io:format("~s : ~s~n", [Sender, Text]),
                                    Message = io_lib:format("~s : ~s", [Sender, Text]),
                                    broadcast({Sender, Type, ReceiverIfPersonal, Message, {date(), time()}}),
                                    SaveMessage = #message_history{primary_key = os:system_time(microsecond), sender = Sender, text = Text, date = date(), time = time()},
                                    Trans1 = fun() ->
                                        mnesia:write(SaveMessage)
                                    end,
                                    mnesia:transaction(Trans1),
                                    {reply, ok, State}
                            end
       
                    end


            end;

        {get_clients, {OgPid}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [] ->
                    {reply, ok, State};
                [_] ->
                    [UserData] = IsConnected,
                    {_, _, _, _, _, _, _} = UserData,
                    Trans1 = fun() ->
                                qlc:e(qlc:q([X#user_data.name || X <- mnesia:table(user_data)]))
                                end,
                    {_, ClientList} = mnesia:transaction(Trans1),
                    Reply = {{date(), time()}, ClientList},
                    {reply, Reply, State}
            end;

        {set_admin, {MyPid, Name}} ->
            Authorised = MyPid == State#state.serverPid,
            case Authorised of
                true ->
                    Trans = fun() ->
                                qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.name == Name]))
                                end,
                    {_, IsUserPresent} = mnesia:transaction(Trans),
                    case IsUserPresent of
                        [_] ->
                            [UserData] = IsUserPresent,
                            {_, _, ReceivingPid, OgPid, _, IsMuted, MutedTill} = UserData,
                            Trans1 = fun() ->
                                        mnesia:write(#user_data{name = Name, pid = ReceivingPid, ogPid = OgPid, isAdmin = 1, isMuted = IsMuted, mutedTill = MutedTill})
                                        end,
                            mnesia:transaction(Trans1),
                            AdminMessage = io_lib:format("~s is now an admin", [Name]),
                            broadcast({"", "", "", AdminMessage, {date(), time()}}),
                            {reply, ok, State};
                        [] ->
                            io:format(Name ++ " user does not exist!~n"),
                            {reply, ok, State}
                    end;
                false ->
                    Trans = fun() ->
                                qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == MyPid]))
                                end,
                    {_, IsConnected} = mnesia:transaction(Trans),
                    case IsConnected of
                        [_] ->
                            [UserData] = IsConnected,
                            {_, AdminName, _, _, IsAdmin, _, _} = UserData,
                            case IsAdmin of
                                1 ->
                                    Trans1 = fun() ->
                                                qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.name == Name]))
                                                end,
                                    {_, IsUserPresent} = mnesia:transaction(Trans1),
                                    case IsUserPresent of
                                        [_] ->
                                            [SecondPersonData] = IsUserPresent,
                                            {_, _, ReceivingPid, OgPid, _, IsMuted, MutedTill} = SecondPersonData,
                                            Trans2 = fun() ->
                                                        mnesia:write(#user_data{name = Name, pid = ReceivingPid, ogPid = OgPid, isAdmin = 1, isMuted = IsMuted, mutedTill = MutedTill})
                                                        end,
                                            mnesia:transaction(Trans2),
                                            AdminMessage = io_lib:format("~s made ~s an admin", [AdminName, Name]),
                                            broadcast({"", "", "", AdminMessage, {date(), time()}}),
                                            {reply, {{date(), time()}, ok}, State};
                                        [] ->
                                            io:format(Name ++ " user does not exist!~n"),
                                            {reply, {{date(), time()}, Name ++ " user does not exist!"}, State}
                                    end;
                                0 ->
                                    {reply, {{date(), time()}, "Dont have enough privilege"}, State}
                            end;
                        [] ->
                            {reply, ok, State}
                    end
            end;

        {kick_user, {AdminPid, KickWhom}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == AdminPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [_] ->
                    [UserData] = IsConnected,
                    {_, AdminName, _, _, IsAdmin, _, _} = UserData,
                    case IsAdmin of
                        1 ->
                            Trans1 = fun() ->
                                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.name == KickWhom]))
                                        end,
                            {_, IsKickWhomPresent} = mnesia:transaction(Trans1),
                            case IsKickWhomPresent of
                                [_] ->
                                    [KickedUserData] = IsKickWhomPresent,
                                    {_, _, ReceivingPid, _, _, _, _} = KickedUserData,
                                    ReceivingPid ! {update, {date(), time()}, "disconnected"},
                                    OId = {user_data, KickWhom},
                                    Trans2 = fun() ->
                                            mnesia:delete(OId) %might give error
                                            end,
                                    mnesia:transaction(Trans2),
                                    io:format(AdminName ++ " kicked out " ++ KickWhom ++ "~n"),
                                    KickMessage = io_lib:format("~s kicked out ~s", [AdminName, KickWhom]),
                                    broadcast({"", "", "", KickMessage, {date(), time()}}),
                                    NewState = State#state{numberOfClients = 1 + State#state.numberOfClients},
                                    {reply, {{date(), time()}, "User kicked"}, NewState};
                                [] ->
                                    {reply, {{date(), time()}, "User not present"}, State}
                            end;
                        0 ->
                            {reply, {{date(), time()}, "Not enough priviledge"}, State}
                    end;
                false ->
                    {reply, ok, State}
            end;

        {set_status, {OgPid, NewStatus}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [] ->
                    {reply, ok, State};
                [_] ->
                    [UserData] = IsConnected,
                    {_, Name, _, _, IsAdmin, _, _} = UserData,
                    case State#state.onlyAdminStatus of
                        0 ->
                            Message = io_lib:format("Status changed by ~s to \' ~s \'", [Name, NewStatus]),
                            io:format(Message ++ "\n"),
                            broadcast({"", "", "", Message, {date(), time()}}),
                            NewState = State#state{status = NewStatus},
                            {reply, {{date(), time()}, "status changed"}, NewState};
                        1 ->
                            case IsAdmin of
                                1 ->
                                    Message = io_lib:format("Status changed by ~s to \' ~s \'", [Name, NewStatus]),
                                    io:format(Message ++ "\n"),
                                    broadcast({"", "", "", Message, {date(), time()}}),
                                    NewState = State#state{status = NewStatus},
                                    {reply, {{date(), time()}, "status changed"}, NewState};
                                0 ->
                                    Reply = {{date(), time()}, "Only admins can change the status"},
                                    {reply, Reply, State}
                            end
                    end
            end;

        {get_status, {OgPid}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [] ->
                    {reply, ok, State};
                [_] ->
                    Reply = {{date(), time()}, State#state.status},
                   {reply, Reply, State}
            end;

        {get_admins_list, {OgPid}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [_] ->
                    [UserData] = IsConnected,
                    {_, _, ReceivingPid, _, _, _, _} = UserData,
                    Trans1 = fun() ->
                                qlc:e(qlc:q([X#user_data.name || X <- mnesia:table(user_data), X#user_data.isAdmin == 1]))
                                end,
                    {_, AdminList} = mnesia:transaction(Trans1),
                    ReceivingPid
                    ! {admin_list, {date(), time()}, AdminList}, % admin list
                    {reply, {{date(), time()}, AdminList}, State};
                [] ->
                    {reply, ok, State}
            end;

        {only_admin_status, MyPid} ->
            Authorised = MyPid == State#state.serverPid,
            case Authorised of
                true ->
                    NewState = State#state{onlyAdminStatus = 1},
                    {reply, ok, NewState};
                false ->
                    {reply, ok, State}
            end;
        
        {mute_user, {OgPid, MuteWhom, MuteFor}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [_] ->
                    [UserData] = IsConnected,
                    {_, AdminName, _, _, IsAdmin, _, _} = UserData,
                    case IsAdmin of
                        1 ->
                            Trans1 = fun() ->
                                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.name == MuteWhom]))
                                        end,
                            {_, IsMuteWhomPresent} = mnesia:transaction(Trans1),
                            case IsMuteWhomPresent of
                                [_] ->
                                    [MutedUserData] = IsMuteWhomPresent,
                                    {_, _, Pid1, OgPid1, IsAdmin1, _, _} = MutedUserData,
                                    EditMutedUserData = #user_data{name = MuteWhom, pid = Pid1, ogPid = OgPid1, isAdmin = IsAdmin1, isMuted = 1, mutedTill = os:system_time(second) + MuteFor*60},
                                    Trans2 = fun() ->
                                        mnesia:write(EditMutedUserData)
                                        end,
                                    mnesia:transaction(Trans2),
                                    MuteMessage = io_lib:format("~s muted ~s", [AdminName, MuteWhom]),
                                    broadcast({"", 0, "", MuteMessage, {date(), time()}}),
                                    {reply, {{date(), time()}, "user muted"}, State};
                                [] ->
                                    {reply, {{date(), time()}, "User does not exist"}, State}
                            end;
                        0 ->
                            Reply = {{date(), time()}, " You cant mute others"},
                            {reply, Reply, State}
                    end;
                [] ->
                    {reply, ok, State}
            end;

        {unmute_user, {OgPid, UnMuteWhom}} ->
            Trans = fun() ->
                        qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.ogPid == OgPid]))
                        end,
            {_, IsConnected} = mnesia:transaction(Trans),
            case IsConnected of
                [_] ->
                    [UserData] = IsConnected,
                    {_, AdminName, _, _, IsAdmin, _, _} = UserData,
                    case IsAdmin of
                        1 ->
                            Trans1 = fun() ->
                                qlc:e(qlc:q([X || X <- mnesia:table(user_data), X#user_data.name == UnMuteWhom]))
                                end,
                            {_, IsUnmuteWhomPresent} = mnesia:transaction(Trans1),
                            case IsUnmuteWhomPresent of
                                [] ->
                                    {reply, ok, State};
                                [_] ->
                                    [MutedUserData] = IsUnmuteWhomPresent,
                                    {_, _, Pid1, OgPid1, IsAdmin1, _, _} = MutedUserData,
                                    SaveUnmutedUserData = #user_data{name = UnMuteWhom, pid = Pid1, ogPid = OgPid1, isAdmin = IsAdmin1, isMuted = 0, mutedTill = 0},
                                    Trans2 = fun() ->
                                        mnesia:write(SaveUnmutedUserData)
                                        end,
                                    mnesia:transaction(Trans2),
                                    UnmuteMessage = io_lib:format("~s unmuted ~s", [AdminName, UnMuteWhom]),
                                    broadcast({"", 0, "", UnmuteMessage, {date(), time()}}),
                                    {reply, {{date(), time()}, "User umuted"}, State}
                            end;
                        0 ->
                            Reply = {{date(), time()}, " You cant unmute others"},
                            {reply, Reply, State}
                    end;
                false ->
                    {reply, ok, State}
            end;

        true ->
            {reply, ok, State}
    end.

set_admin(ServerNode, Name) ->
    gen_server:call({server, ServerNode}, {set_admin, {self(), Name}}),
    ok.

only_admin_status(ServerNode) ->
    gen_server:call({server, ServerNode}, {only_admin_status, self()}),
    ok.

broadcast({Sender, Type, ReceiverIfPersonal, Text, DateTime}) ->
    Trans = fun() ->
        qlc:e(qlc:q([X#user_data.pid || X <- mnesia:table(user_data)]))
    end,
    {_, AllPids} = mnesia:transaction(Trans),
    lists:foreach(fun(X) -> X ! {message, Sender, Type, ReceiverIfPersonal, Text, DateTime} end, AllPids).

send_prev_messages(Pid, PrevMessagesLimit) ->
    F = fun() ->
        qlc:e(qlc:q([X || X <- mnesia:table(message_history)]))
        end,
    {_, Val} = mnesia:transaction(F),
    Messages = lists:keysort(2, Val), 
    Len = length(Messages),
    if Len > PrevMessagesLimit ->
           Pid ! {prev_messages, lists:nthtail(Len - PrevMessagesLimit, Messages)},
           ok;
       true ->
           Pid ! {prev_messages, Messages},
           ok
    end.

message_history() ->
    Trans = fun() ->
        qlc:e(qlc:q([X || X <- mnesia:table(message_history)]))
        end,
    {_, Val} = mnesia:transaction(Trans),
    List = lists:keysort(2, Val),
    print_messages(List).

send_offline_messages(Pid, Name) ->
   Trans = fun() ->
        qlc:e(qlc:q([X || X <- mnesia:table(offline_messages), X#offline_messages.receiver == Name]))
        end,
    {_, Val} = mnesia:transaction(Trans), 
    
    case Val of
        [] ->
            ok;
        [_] ->
            List = lists:keysort(2, Val),
            Pid ! {offline_messages, List},
            ok
    end.


print_messages([]) ->
    done;
print_messages(L) ->
    [H | T] = L,
    {_, _, Sender, Message, Date, Time} = H,
    print_datetime({Date, Time}),
    io:format("~s : ~s~n", [Sender, Message]),
    print_messages(T).

print_datetime(DateTime) ->
    {Date, Time} = DateTime,
    {H, M, S} = Time,
    {Y, Month, D} = Date,
    io:format("[~2..0w/~2..0w/~4..0w  ~2..0w:~2..0w:~2..0w] ", [D, Month, Y, H, M, S]).