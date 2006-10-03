%%%-------------------------------------------------------------------
%%% File    : active_subscription.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: Handle a single SUBSCRIBE dialog. Refreshes the sub-
%%%           scription and sends all NOTIFYs we receive to our
%%%           parent process (the active_subscriber) using
%%%           gen_server:cast({received_notify, ...})
%%%
%%% NOTE    : This module isn't used by the event server for now, it
%%%           was just usable during development, possibly usable as
%%%           an example and possibly also needed for some future
%%%           event package.
%%%
%%% Created : 12 May 2006 by Fredrik Thulin <ft@it.su.se>
%%%-------------------------------------------------------------------
-module(active_subscription).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([start_link/10
	]).

%%--------------------------------------------------------------------
%% Internal exports - gen_server callbacks
%%--------------------------------------------------------------------
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("siprecords.hrl").
-include("event.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

-record(state, {uri,			%% sipurl record(), remote target (or where to send SUBSCRIBE request)
		interval,		%% integer(), number of seconds until our subscription terminates (what we ask for anyways)
		extra_headers,		%% list() of {Key, ValueL} - extra SIP headers to put in SUBSCRIBEs
		res_extra_h,		%% list() of {Key, ValueL} - extra SIP headers to put in responses we send

		branch_base,		%% string(),
		branch_seq = 1,		%% integer()
		dialog,			%% dialog record()
		my_accept,		%% list() of string(), "Accept" header extracted from ExtraHeaders
		my_contact,		%% [string()], "Contact" header extracted from ExtraHeaders

		parent,			%% pid() of our parent process

		subscribe_pid,		%% undefined | pid(), pid of current SUBSCRIBE client transaction
		subscribe_requri,	%% undefined | sipurl record(), Request-URI of current SUBSCRIBE
		sent_subscr_ts = 0,
		last_notify_ts = 0,	%% integer(), util:timestamp() notion of when we last received a NOTIFY
		mystate = init		%% init | active | stop | stopped
	       }).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
-define(DEFAULT_EXPIRE_TIME, 600).
-define(REFRESH_SUBSCRIPTION_AFTER, 0.8).
-define(DIALOG_GRACE_PERIOD, 60).



%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: start(PackageS, Presenter, SInterval, Accept, ExtraH,
%%                 EventSuffix, LogTag, Parent)

%% XXX COMPLETE
%%           SInterval   = integer(), SUBSCRIBE expire time in seconds
%%           ExtraH      = list() of {Key, ValueL}, extra headers to
%%                         set in our SUBSCRIBEs
%%           Parent      = pid()

%% Descrip.: Starts the active_subscriber gen_server.
%%
%% NOTE    : ExtraH MUST include one (and only one) of the following :
%%           "Contact", "Event" and "Accept"
%%
%% Returns : Pid = pid() | {error, Reason}
%%           Reason = {siperror, Status, Reason, EH} |
%%           term()
%%--------------------------------------------------------------------
start_link(#request{method = "NOTIFY"} = Request, Origin, LogStr, THandler, BranchBase, Parent, ParentState,
	   Interval, ExtraH, FirstCSeq) ->

    %% verify that mandatory values are present in ExtraH
    {value, {_, [MyContact]}} = lists:keysearch("Contact", 1, ExtraH),
    {value, _} = lists:keysearch("Event", 1, ExtraH),
    {value, {_, MyAccept}} = lists:keysearch("Accept", 1, ExtraH),

    %% Create extra headers to use in responses we send
    ResExtraH =
	case lists:keysearch("User-Agent", 1, ExtraH) of
	    {value, {"User-Agent", UA}} ->
		[{"Server", UA}];
	    false ->
		[]
	end,

    State1 = #state{branch_base		= BranchBase,
		    parent		= Parent,
		    interval		= Interval,
		    extra_headers	= ExtraH,
		    res_extra_h		= ResExtraH,
		    my_contact		= MyContact,
		    my_accept		= MyAccept,
		    sent_subscr_ts	= util:timestamp() %% well, not really but...
		   },

    gen_server:start_link(?MODULE, [State1, Request, Origin, LogStr, THandler, ParentState, FirstCSeq], []).


%%====================================================================
%% Behaviour functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init([State1, Request, ParentState])
%%           State1 = state record(), state in
%%           XXX
%% Descrip.: Initiates the server
%% Returns : {ok, State}          |
%%           ignore               |
%%           {stop, Reason}
%%--------------------------------------------------------------------
init([State1, Request, Origin, LogStr, THandler, ParentState, FirstCSeq]) ->
    Expires = get_subscription_state_expires(Request#request.header, State1#state.interval),

    {ok, ToTag} = transactionlayer:get_my_to_tag(THandler),
    {ok, Dialog1} = local:create_dialog_state_uas(?MODULE, Request, ToTag, State1#state.my_contact),
    Dialog = Dialog1#dialog{local_cseq = FirstCSeq},

    State2 = State1#state{dialog = Dialog},

    %% First, we register as handler for this dialog
    ok = sipdialog:register_dialog_controller(Dialog, self(), Expires + ?DIALOG_GRACE_PERIOD),

    %% if ParentState is 'stop', we send a SUBSCRIBE with expires 0, otherwise we set up a refresh timer
    %% and process the NOTIFY
    case ParentState of
	stop ->
	    %% Then, we answer 200 Ok
	    transactionlayer:send_response_handler(THandler, 200, "Ok", State2#state.res_extra_h),

	    logger:log(debug, "Active subscription: Unsubscribing since parent state was 'stop'"),
	    State = send_subscribe(0, State2),
	    {ok, State};
	_ ->
	    %% Calculate refresh interval
	    RefreshInterval = round((Expires * ?REFRESH_SUBSCRIPTION_AFTER) * 1000),
	    {ok, _TRef} = timer:send_after(RefreshInterval, refresh_subscription),

	    logger:log(debug, "Active subscription: Started (NOTIFY ~s)", [sipurl:print(Request#request.uri)]),

	    case process_received_notify(Request, Origin, LogStr, THandler, State2) of
		{noreply, State} ->
		    {ok, State};
		{stop, normal, _State} ->
		    %% NOTIFY had Subscription-State indicating the subscription was terminated
		    ignore
	    end
    end.

%%--------------------------------------------------------------------
%% Function: handle_call(Msg, From, State)
%% Descrip.: Handling call messages
%% Returns : {reply, Reply, State}          |
%%           {reply, Reply, State, Timeout} |
%%           {noreply, State}               |
%%           {noreply, State, Timeout}      |
%%           {stop, Reason, Reply, State}   | (terminate/2 is called)
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------

handle_call({set_interval, NewInterval}, _From, State) when is_integer(NewInterval) ->
    %% XXX send a new SUBSCRIBE? Only do it if interval is decreased?
    {reply, ok, State#state{interval = NewInterval}};

handle_call(Msg, _From, State) ->
    logger:log(error, "Active subscription: Received unknown gen_server call : ~p", [Msg]),
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State)
%% Descrip.: Handling cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------


handle_cast(Msg, State) ->
    logger:log(error, "Active subscription: Received unknown gen_server cast : ~p", [Msg]),
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: handle_info(Msg, State)
%% Descrip.: Handling all non call/cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------


%%--------------------------------------------------------------------
%% Function: handle_info({branch_result, ...}, State)
%% Descrip.: A SUBSCRIBE client transaction we started resulted in a
%%           response. Check if that response was a (received) 481 and
%%           terminate if it was.
%% Returns : {noreply, State, Timeout} |
%%           {stop, Reason, State}
%%--------------------------------------------------------------------
handle_info({branch_result, FromPid, Branch, SipState, Response}, State) ->
    Status =
	case Response of
	    #response{status = Status1} ->
		Status1;
	    {Status1, _Reason1} ->
		Status1
	end,

    case (FromPid == State#state.subscribe_pid) of
	true ->
	    case SipState of
		completed when is_record(Response, response), Status >= 200, Status =< 299 ->
		    NewState1 = process_subscribe_2xx_response(Response, State),
		    %% clear subscribe_pid as soon as we receive a final response so that a
		    %% new SUBSCRIBE can be sent
		    NewState = NewState1#state{subscribe_pid = undefined},
		    {noreply, NewState};
		completed when Status >= 300 ->
		    %% If this was a refresh that received a non-481 response, the subscription is actually still
		    %% to be considered valid until it expires - RFC3265 #3.1.4.2 (Refreshing of Subscriptions) -
		    %% but we terminate right away for now.
		    URI = State#state.subscribe_requri,
		    logger:log(normal, "Active subscription: SUBSCRIBE ~s resulted in ~p response, terminating "
			       "the subscription immediately.", [sipurl:print(URI), Status]),
		    {stop, normal, State};
		_ ->
		    %% either SipState was not completed, or the response was 2xx. Clean subscribe_pid
		    %% on any final response though so that a new SUBSCRIBE can be sent
		    NewState =
			case Status >= 200 of
			    true  -> State#state{subscribe_pid = undefined};
			    false -> State
			end,
		    {noreply, NewState}
	    end;
	false ->
	    logger:log(debug, "Active subscription: Ignoring branch_result from ~p (~p) : ~p",
		       [FromPid, Branch, Response]),
	    {noreply, State}
    end;

handle_info(refresh_subscription, State) ->
    logger:log(debug, "Active subscription: Extra debug: Received signal to refresh my subscription"),
    Now = util:timestamp(),

    Expires =
	case (State#state.last_notify_ts < State#state.sent_subscr_ts) of
	    true ->
		%% If the subscription interval is shorter than 32 seconds (non-INVITE request timeout),
		%% we must give the presenter the benefit of a doubt
		case (State#state.sent_subscr_ts >= Now - 32) of
		    true ->
			%% XXX debug log level
			logger:log(normal, "Active subscription: Refreshing subscription"),
			State#state.interval;
		    false ->
			case State#state.last_notify_ts of
			    0 ->
				logger:log(normal, "Active subscription: Terminating instead of renewing, "
					   "I never received a NOTIFY");
			    _ ->
				logger:log(normal, "Active subscription: Terminating instead of renewing, "
					   "we haven't received a NOTIFY since we sent our last SUBSCRIBE")
			end,
			0
		end;
	    false ->
		%% XXX debug log level
		logger:log(normal, "Active subscription: Refreshing subscription"),
		State#state.interval
	end,

    NewState = send_subscribe(Expires, State),
    {noreply, NewState};


%%--------------------------------------------------------------------
%% Function: handle_info({clienttransaction_terminating, ...}, State)
%% Descrip.: A SUBSCRIBE client transaction has terminated. Remove it
%%           from our list of active SUBSCRIBE client transactions.
%% Returns : {noreply, State, Timeout}
%%--------------------------------------------------------------------
handle_info({clienttransaction_terminating, FromPid, _Branch}, State) ->
    NewState =
	case (FromPid == State#state.subscribe_pid) of
	    true ->
		%% clear subscribe_pid
		State#state{subscribe_pid = undefined};
	    false ->
		%% this does not have to be an error if we started a new SUBSCRIBE between when the
		%% branch_result with a final response was received, and the old SUBSCRIBE terminated,
		%% so we don't even log it
		State
	end,
    {noreply, NewState};

%%--------------------------------------------------------------------
%% Function: handle_info({servertransaction_terminating, ...}, State)
%% Descrip.: A SUBSCRIBE server transaction (probably) has terminated,
%%           just ignore.
%% Returns : {noreply, State, Timeout}
%%--------------------------------------------------------------------
handle_info({servertransaction_terminating, _FromPid}, State) ->
    {noreply, State};

%%--------------------------------------------------------------------
%% Function: handle_info({new_request, FromPid, Ref, NewRequest,
%%                       Origin, LogStr}, ...)
%%           FromPid    = pid(), transaction layer
%%           Ref        = ref(), unique reference to ack this message
%%                               with (signal back to transaction
%%                               layer)
%%           NewRequest = request record()
%%           Origin     = siporigin record(),
%%           LogStr     = string(), textual description of request
%% Descrip.: Handle incoming requests on our dialog.
%% Returns : {noreply, State, Timeout}      |
%%           {stop, normal, State}
%%--------------------------------------------------------------------
handle_info({new_request, FromPid, Ref, NewRequest, Origin, LogStr}, State) when is_record(NewRequest, request) ->
    THandler = transactionlayer:get_handler_for_request(NewRequest),
    transactionlayer:adopt_server_transaction_handler(THandler),
    FromPid ! {ok, self(), Ref},

    case sipdialog:update_dialog_recv_request(NewRequest, State#state.dialog) of
	{error, old_cseq} ->
	    transactionlayer:send_response_handler(THandler, 500, "CSeq not higher than last requests",
						   State#state.res_extra_h),
	    {noreply, State};
	{ok, NewDialog} ->
	    case NewRequest#request.method of
		"NOTIFY" ->
		    process_received_notify(NewRequest, Origin, LogStr, THandler, State);
		_ ->
		    transactionlayer:send_response_handler(THandler, 501, "Not Implemented (inside dialog)",
							   State#state.res_extra_h),
		    {noreply, State#state{dialog = NewDialog}}
	    end
    end;

%%--------------------------------------------------------------------
%% Function: handle_info({dialog_expired, ...}, State)
%% Descrip.: This should never happen, but the transaction layer just
%%           signaled us that this dialog has expired. Log an error
%%           message and exit. This almost certainly means that a bug
%%           was encountered, since we should otherwise have noticed
%%           that the subscription expired and exited ourselves.
%% Returns : {stop, normal, State}
%%--------------------------------------------------------------------
handle_info({dialog_expired, _DialogId}, State) ->
    logger:log(error, "Active subscription: Dialog expired, should not happen."),
    {stop, normal, State};

handle_info(Unknown, State) ->
    logger:log(error, "Active subscription: Received unknown gen_server info : ~p", [Unknown]),
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: terminate(Reason, State)
%% Descrip.: The server is being shut down. Remove ourselves from the
%%           ets table with subscriptions for presentitys before we
%%           terminate.
%% Returns : any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    case Reason of
        normal -> logger:log(debug, "Active subscription: terminating normally");
        shutdown -> logger:log(debug, "Active subscription: shutting down");
        _ -> logger:log(error, "Active subscription: terminating : ~p", [Reason])
    end,

    Reason.

%%--------------------------------------------------------------------
%% Function: code_change(OldVsn, State, Extra)
%% Descrip.: Convert process state when code is changed
%% Returns : {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% Internal functions
%%====================================================================


%%--------------------------------------------------------------------
%% Function: process_subscribe_2xx_response(Response, State)
%%           Response = response record()
%%           State    = state record()
%% Descrip.: Process a 2xx response to a SUBSCRIBE we sent.
%% Returns : NewState = state record()
%%--------------------------------------------------------------------
process_subscribe_2xx_response(Response, State) ->
    Expires =
	case sipheader:expires(Response#response.header) of
	    [ExpireStr] ->
		list_to_integer(ExpireStr);
	    [] ->
		logger:log(debug, "Active subscription: Warning: Server did not include an "
			   "Expires: header in it's response! Assuming we got what we asked for."),
		State#state.interval
	end,

    %% Calculate refresh interval
    RefreshInterval = round((Expires * ?REFRESH_SUBSCRIPTION_AFTER) * 1000),
    {ok, _TRef} = timer:send_after(RefreshInterval, refresh_subscription),

    ok = sipdialog:set_dialog_expires(State#state.dialog, Expires + ?DIALOG_GRACE_PERIOD),

    NewMyState =
	case State#state.mystate of
	    init -> active;
	    Old -> Old
	end,

    NewState1 =
	State#state{subscribe_requri	= undefined,
		    mystate		= NewMyState
		   },

    case NewState1#state.mystate of
	stop ->
	    %% we have been requested to stop, but did not do that right away since we had
	    %% a SUBSCRIBE running already, do it now
	    logger:log(normal, "Active subscription: Stopping now that the ongoing SUBSCRIBE has finished"),
	    send_subscribe(0, NewState1);
	_ ->
	    %% XXX debug log level
	    logger:log(normal, "Active subscription: Established subscription, will renew in ~p seconds",
		       [RefreshInterval div 1000]),
	    NewState1
    end.


%%--------------------------------------------------------------------
%% Function: send_subscribe(Expires, State)
%%           Expires = integer()
%%           State   = state record()
%% Descrip.: Send a SUBSCRIBE request.
%% Returns : NewState = state record()
%%--------------------------------------------------------------------
send_subscribe(Expires, State) when is_integer(Expires), State#state.subscribe_pid == undefined ->
    ExtraHeaders = State#state.extra_headers ++ [{"Expires", [integer_to_list(Expires)]}],

    {ok, Request, NewDialog, Dst} = sipdialog:generate_new_request("SUBSCRIBE", ExtraHeaders,
								   <<>>, State#state.dialog),

    Timeout = 5,
    BranchSeq = State#state.branch_seq,
    Branch = lists:concat([State#state.branch_base, BranchSeq]),

    [FirstDst | _] = Dst,	%% XXX don't just throw away the other destinations!
    Pid = transactionlayer:start_client_transaction(Request, FirstDst, Branch, Timeout, self()),

    NewMyState =
	case Expires of
	    0 -> stopped;
	    _ -> State#state.mystate
	end,

    State#state{branch_seq		= BranchSeq + 1,
		subscribe_pid		= Pid,
		subscribe_requri	= Request#request.uri,
		dialog			= NewDialog,
		mystate			= NewMyState,
		sent_subscr_ts		= util:timestamp()
	       }.


%%--------------------------------------------------------------------
%% Function: process_received_notify(Request, Origin, LogStr,
%%                                   THandler, State)
%%           Request  = request record()
%%           Origin   = siporigin record()
%%           LogStr   = string(), describes Request
%%           THandler = term(), server transaction handler
%%           State    = state record()
%% Descrip.: Process a NOTIFY request we have received.
%% Returns : {noreply, NewState}      |
%%           {stop, normal, NewState}
%%           NewState = state record()
%%--------------------------------------------------------------------
process_received_notify(Request, Origin, LogStr, THandler, State) when is_record(Request, request),
								       is_record(State, state) ->
    Now = util:timestamp(),
    NewState1 = State#state{last_notify_ts = Now},

    SubState =
	case keylist:fetch("Subscription-State", Request#request.header) of
	    [] ->
		ok;
	    [SubStateV] ->
		{ok, L} = sipparse_util:split_non_quoted(59, SubStateV),	%% 59 is semi-colon
		%% RFC3265 #3.2.4 (Subscriber NOTIFY Behavior)
		SubscriptionState = http_util:to_lower(hd(L)),
	        Action =
		    case SubscriptionState of
			"active"	-> ignore;
			"pending"	-> ignore;
			"deactivated"	-> {retry, 0};
			"probation"	-> {retry, get_retry_after(Request#request.header, 0)};
			"rejected"	-> terminate;
			"timeout"	-> {retry, 0};
			"giveup"	-> terminate;
			"noresource"	-> terminate;
			_		-> {retry, get_retry_after(Request#request.header, 0)}
		    end,

		case Action of
		    ignore ->
			ok;
		    {retry, RetryAfter} ->
			logger:log(normal, "Active subscription: Other side deactivated subscription. "
				   "We should retry after ~p seconds, but that is not implemented yet!",
				   [RetryAfter]),
			terminate;
		    terminate ->
			logger:log(normal, "Active subscription: Other side terminated subscription (~s)",
				  [SubscriptionState]),
			terminate
		end
	end,

    case check_is_acceptable(Request, State#state.my_accept) of
	ok ->
	    case Request#request.body of
		<<>> ->
		    ok;
		_ ->
		    %% process the body
		    Dialog = State#state.dialog,
		    DialogId = {Dialog#dialog.callid, Dialog#dialog.local_tag, Dialog#dialog.remote_tag},

                    Ctx = #event_ctx{dialog_id = DialogId},
		    gen_server:cast(State#state.parent, {received_notify, self(), Request, Origin, LogStr,
							 THandler, Ctx}),

		    {noreply, NewState1}
	    end;
	{siperror, Status, Reason, EH} ->
	    transactionlayer:send_response_handler(THandler, Status, Reason, EH ++ State#state.res_extra_h),
	    {noreply, NewState1}
    end,

    case SubState of
	ok ->
	    {noreply, State};
	terminate ->
	    {stop, normal, State#state{mystate = stopped}};
	_ ->
	    SubState
    end.




%%--------------------------------------------------------------------
%% Function: check_is_acceptable(Request, AcceptL)
%%           Request = request record()
%%           AcceptL = list() of string()
%% Descrip.: Check if the Content-Type of Request matches any element
%%           in AcceptL (the list of accepted content types).
%% Returns : ok | SipError
%%           SipError = {siperror, Status, Reason, EH}
%%--------------------------------------------------------------------
check_is_acceptable(Request, AcceptL) ->
    case keylist:fetch('content-type', Request#request.header) of
	[Acc1] ->
	    Accept = http_util:to_lower(Acc1),
	    case lists:member(Accept, AcceptL) of
		true ->
		    ok;
		false ->
		    {siperror, 406, "Not Acceptable", []}
	    end;
	[] ->
	    ok
    end.

%%--------------------------------------------------------------------
%% Function: get_subscription_state_expires(Header, Default)
%%           Header  = keylist record()
%%           Default = integer()
%% Descrip.: Check for an Subscription-State header with an expires
%%           parameter, or return Default if no expires parameter is
%%           found, or it does not contain an integer.
%% Returns : Seconds = integer()
%%--------------------------------------------------------------------
get_subscription_state_expires(Header, Default) when is_integer(Default) ->
    case keylist:fetch("Subscription-State", Header) of
	[] ->
	    Default;
	[SubStateV] ->
	    case sipparse_util:split_non_quoted(59, SubStateV) of	%% 59 is semi-colon
		{ok, L} ->
		    get_subscription_state_expires2(L, Default);
		_ ->
		    Default
	    end
    end.

get_subscription_state_expires2([H | T], Default) ->
    case string:strip(http_util:to_lower(H)) of
	"expires=" ++ Rest ->
	    try list_to_integer(Rest) of
		Val ->
		    {ok, Val}
	    catch
		_: _ ->
		    none
	    end;
	_ ->
	    get_subscription_state_expires2(T, Default)
    end;
get_subscription_state_expires2([], Default) ->
    Default.


%%--------------------------------------------------------------------
%% Function: get_retry_after(Header, Default)
%%           Header  = keylist record()
%%           Default = integer()
%% Descrip.: Check for an Retry-After header, and retun it's value or
%%           return Default if no value is found, or it does not
%%           contain an integer.
%% Returns : Seconds = integer()
%%--------------------------------------------------------------------
get_retry_after(Header, Default) when is_integer(Default) ->
    case keylist:fetch('retry-after', Header) of
	[RAStr] ->
	    try list_to_integer(RAStr) of
		RA when is_integer(RA) -> RA
	    catch
		_: _ -> Default
	    end;
	_ ->
	    Default
    end.
