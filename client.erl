-module(client).
-compile(export_all).


start(ServerNode, Name) ->
    Var1 = spawn(client, loop, [Name, self(), ServerNode]),
    put(loop_pid, Var1),
    Var1 ! {connect},
    ok.


loop(Name, OgPid, ServerNode) ->
    receive
        {connect} ->
            Response = gen_server:call({server, ServerNode}, {connect, {Name, self(), OgPid}}),
            io:format("~s~n", [Response]),
            loop(Name, OgPid, ServerNode);

        {update, DateTime, Response} ->
            print_datetime(DateTime),
            io:format(Response ++ "~n"),
            case Response of
                "disconnected" ->
                    exit(1);
                _ ->
                    loop(Name, OgPid, ServerNode)
            end;

        {offline_messages, Messages} ->
            io:format("Your offline messages ~n"),
            print_offline_messages(Messages),
            loop(Name, OgPid, ServerNode);

        {prev_messages, Response} ->
            Len = length(Response),
            case Len > 0 of
                false ->
                    no_prev_messages;
                true ->
                    io:format("Prev Messages --> ~n"),
                    print_prev_messages(Response),
                    list_received
            end,
            loop(Name, OgPid, ServerNode);

        {message, Sender, Type, _, Text, DateTime} ->
            print_datetime(DateTime),
            if
                Type == 1 ->
                    io:format("[Private Message] ");
                true -> 
                    ok
            end,
            if
                Sender == "" ->
                    % timer:sleep(10),
                    io:format("~s~n", [Text]),
                    loop(Name, OgPid, ServerNode);
                true ->
                    io:format("~s~n", [Text]),
                    loop(Name, OgPid, ServerNode)
            end;

        {get_clients} ->
            Response = gen_server:call({server, ServerNode}, {get_clients, {OgPid}}),
            {DateTime, ClientList} = Response,
            print_datetime(DateTime),
            io:format("List of online users : ~n"),
            print_client_list(ClientList),
            loop(Name, OgPid, ServerNode);

        {get_admins} ->
            Response = gen_server:call({server, ServerNode}, {get_admins_list, {OgPid}}),
            {DateTime, AdminList} = Response,
            print_datetime(DateTime),
            io:format("List of admins : ~n"),
            print_client_list(AdminList),
            loop(Name, OgPid, ServerNode);

        {set_admin, AdminName} ->
            Response = gen_server:call({server, ServerNode}, {set_admin, {OgPid, AdminName}}),
            {DateTime, Reply} = Response,
            print_datetime(DateTime),
            io:format("~s~n", [Reply]),
            loop(Name, OgPid, ServerNode);
        
        {send_message_all, Text} ->
            Response = gen_server:call({server, ServerNode}, {message, {OgPid, 0, "", Text}}),
            io:format("~s~n",[Response]),
            loop(Name, OgPid, ServerNode);
        
        {send_message_private, RecieverIfPersonal, Text} ->
            gen_server:call({server, ServerNode}, {message, {OgPid, 1, RecieverIfPersonal, Text}}),
            ok,
            loop(Name, OgPid, ServerNode);

        {kick_user, KickWhom} ->
            Response = gen_server:call({server, ServerNode}, {kick_user, {OgPid, KickWhom}}),
            {DateTime, Reply} = Response,
            print_datetime(DateTime),
            io:format("~s~n", [Reply]),
            loop(Name, OgPid, ServerNode);

        {mute_user, MuteWhom, MuteFor} ->
            Response = gen_server:call({server, ServerNode}, {mute_user, {OgPid, MuteWhom, MuteFor}}),
            {DateTime, Reply} = Response,
            print_datetime(DateTime),
            io:format("~s~n", [Reply]),
            loop(Name, OgPid, ServerNode);

        {unmute_user, UnMuteWhom} ->
            Response = gen_server:call({server, ServerNode}, {unmute_user, {OgPid, UnMuteWhom}}),
            {DateTime, Reply} = Response,
            print_datetime(DateTime),
            io:format("~s~n", [Reply]),
            loop(Name, OgPid, ServerNode);

        {set_status, NewStatus} ->
            Response = gen_server:call({server, ServerNode}, {set_status, {OgPid, NewStatus}}),
            {DateTime, Reply} = Response,
            print_datetime(DateTime),
            io:format("~s~n", [Reply]),
            loop(Name, OgPid, ServerNode);

        {get_status} ->
            Response = gen_server:call({server, ServerNode}, {get_status, {OgPid}}),
            {DateTime, Reply} = Response,
            print_datetime(DateTime),
            io:format("Current status : ~s~n", [Reply]),
            loop(Name, OgPid, ServerNode);

        true ->
            loop(Name, OgPid, ServerNode)
    end.
                
get_clients() ->
    get(loop_pid) ! {get_clients},
    ok.
get_admins() ->
    get(loop_pid) ! {get_admins},
    done.

set_admin(Name) ->
    get(loop_pid) ! {set_admin, Name},
    ok.

send_message_all(Text) ->
    get(loop_pid) ! {send_message_all, Text},
    ok.

send_message_private(RecieverIfPersonal, Text) ->
    get(loop_pid) ! {send_message_private, RecieverIfPersonal, Text},
    ok.

kick_user(KickWhom) ->
    get(loop_pid) ! {kick_user, KickWhom},
    ok.

mute_user(MuteWhom, MuteFor) ->
    get(loop_pid) ! {mute_user, MuteWhom, MuteFor},
    ok.

unmute_user(UnMuteWhom) ->
    get(loop_pid) ! {unmute_user, UnMuteWhom},
    ok.

disconnect(ServerNode) ->
    gen_server:call({server, ServerNode}, {disconnect, {self()}}),
    ok.

set_status(NewStatus) ->
    get(loop_pid) ! {set_status, NewStatus},
    ok.

get_status() ->
    get(loop_pid) ! {get_status},
    ok.
    

print_client_list([]) ->
    done;
print_client_list(L) ->
    [H | T] = L,
    io:format("~s~n", [H]),
    print_client_list(T).

print_prev_messages([]) ->
    done;
print_prev_messages(L) ->
    [H | T] = L,
    {_, _, Sender, Text, Date, Time} = H,
    print_datetime({Date, Time}),
    io:format("~s : ~s~n", [Sender, Text]),
    print_prev_messages(T).

print_offline_messages([]) ->
    done;
print_offline_messages(L) ->
    [H | T] = L,
    {_, _, _, Sender, Text, Date, Time} = H,
    print_datetime({Date, Time}),
    io:format("~s : ~s~n", [Sender, Text]),
    print_offline_messages(T).

print_datetime(DateTime) ->
    {Date, Time} = DateTime,
    {H, M, S} = Time,
    {Y, Month, D} = Date,
    io:format("[~2..0w/~2..0w/~4..0w  ~2..0w:~2..0w:~2..0w] ", [D, Month, Y, H, M, S]).



% ge_server:call({server, node name}, Request)