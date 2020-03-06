
-- standard MSI protocol

---------------------------------------------------------------------------------
-- Constants---------------------------------------------------------------------
---------------------------------------------------------------------------------
const
	ProcCount: 2;			-- number of processors
	ValueCount:	 2;			-- number of data values
	NumVCs: 3;				-- number of virtual channels
	RequestChannel: 0;		-- virtual channel #0
	ForwardChannel: 1;		-- virtual channel #1
	ResponseChannel: 2;		-- virtual channel #2
	NetMax: ProcCount*3; 	-- network capacity (infinite)
	

---------------------------------------------------------------------------------
-- Types-------------------------------------------------------------------------
---------------------------------------------------------------------------------
type
	Proc: scalarset(ProcCount);	  	-- unordered range of processors
	Value: scalarset(ValueCount); 	-- arbitrary values for tracking coherence
	Mem: enum { MemType };	  		-- need enumeration for IsMember calls
	Node: union { Mem , Proc };		-- track node type

	VCType: 0..NumVCs-1;
	AckCount: 0..ProcCount-1;

	-- define enum for message types
	MessageType: enum {	 
		GetS,		-- RequestChannel
		GetM,
		PutM,
		PutS,
		FwdGetS,	-- ForwardChannel
		FwdGetM,
		Inv,
		PutAck,
		PutLast,    -- (if Proc is last sharer, it's told it's the last one)
		Data,		-- ResponseChannel
		InvAck,
		FwdAck,
		PutLastAck
	};

	-- define message
	Message:
		Record
			mtype: MessageType;
			src: Node;
			-- do not need a destination for verification; the destination is 
			-- indicated by which array entry in the Net the message is placed
			vc: VCType;
			val: Value;
			who: Node; -- tells procs which proc to forward data to
			ack: AckCount;	-- needed for Data messages to count expected Acks
		end;

	MemState:
		Record
			state: enum { -- directory controller states
				M_I,
				M_S,
				M_SI_A,
				M_S_D,
				M_M,
				M_MM_A
			};
			owner: Node;	
			sharers: multiset [ProcCount] of Node;		
			val: Value; 
		end;

	ProcState:
		Record
			state: enum { -- cache controller states
				P_I,
				P_II_A,
				P_IS_D,
				P_MI_A,
				P_SI_A,
				P_IM_A,
				P_S,
				P_IM_AD,
				P_SM_A,
				P_SM_AD,
				P_M
			};
			val: Value;
			acks_needed: AckCount;
			acks_received: AckCount;
		end;

---------------------------------------------------------------------------------
-- Variables---------------------------------------------------------------------
---------------------------------------------------------------------------------
var
	MemNode: MemState;
	Procs: array [Proc] of ProcState;
	-- One multiset for each dest: messages arbitrarily reordered by multiset
	Net:   array [Node] of multiset [NetMax] of Message;		
	-- If a message not processed, placed in InBox, blocking that virtual channel
	InBox: array [Node] of array [VCType] of Message; 
	msg_processed: boolean;
	-- confirm that writes are not lost; would not exist in real hardware
	LastWrite: Value; 

---------------------------------------------------------------------------------
-- procedures--------------------------------------------------------------------
---------------------------------------------------------------------------------
procedure Send(mtype: MessageType;
				 dst: Node;
				 src: Node;
				 vc: VCType;
				 val: Value;
				 who: Node;
				 ack: AckCount;
			 );
var msg: Message;
begin
	Assert (MultiSetCount(i: Net[dst], true) < NetMax) "Too many messages";
	msg.mtype:= mtype;
	msg.src	 := src;
	msg.vc	 := vc;
	msg.val	 := val;
	msg.who  := who;
	msg.ack  := ack;
	MultiSetAdd(msg, Net[dst]);
end;

---------------------------------------------------------------------------------

procedure ErrorUnhandledMsg(msg: Message; n: Node);
begin
	error "Unhandled message type!";
end;

---------------------------------------------------------------------------------

procedure ErrorUnhandledState();
begin
	error "Unhandled state!";
end;

---------------------------------------------------------------------------------

procedure AddToSharersList(n: Node);
begin
	if MultiSetCount(i: MemNode.sharers, MemNode.sharers[i] = n) = 0
	then
		MultiSetAdd(n, MemNode.sharers);
	endif;
end;

---------------------------------------------------------------------------------

Function IsSharer(n: Node) : Boolean;
begin
	return MultiSetCount(i: MemNode.sharers, MemNode.sharers[i] = n) > 0
end;

---------------------------------------------------------------------------------

procedure RemoveFromSharersList(n: Node);
begin
	MultiSetRemovePred(i: MemNode.sharers, MemNode.sharers[i] = n);
end;

---------------------------------------------------------------------------------

-- Sends a message to all sharers except rqst
procedure SendInvReqToSharers(rqst: Node);
begin
	for n: Node do
		-- if it's a processor and is a sharer
		if (IsMember(n, Proc) &
				MultiSetCount(i: MemNode.sharers, MemNode.sharers[i] = n) != 0)
		then
			-- don't invalidate the requestor
			if n != rqst
			then 
				-- send invalidation from requestor to all other sharer procs
				Send(Inv, n, rqst, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED)
			endif;
		endif;
	endfor;
end;

---------------------------------------------------------------------------------

-- memory controller is receiving a message
procedure MemReceive(msg: Message);
var cnt: 0..ProcCount;	-- for counting sharers
begin

	-- Debug output may be helpful:
	put "Mem receiving "; put msg.mtype; put " from "; put msg.src;  put " on VC"; put msg.vc; put " "; put MemNode.state;

	-- pre-calculate the sharer count here
	cnt := MultiSetCount(i: MemNode.sharers, true);

	-- default to 'processing' message,	set to false if stalling
	msg_processed := true;

	switch MemNode.state
	case M_I:
		switch msg.mtype
		case GetS:
			MemNode.state := M_S;
			AddToSharersList(msg.src);
			-- existing sharers can be ignored since the data is read-only
			Send(Data, msg.src, MemType, ResponseChannel, MemNode.val, UNDEFINED, 0);
		case GetM:
			MemNode.state := M_M;
			MemNode.owner := msg.src;
			-- should not be any sharers, cnt = 0
			Send(Data, msg.src, MemType, ResponseChannel, MemNode.val, UNDEFINED, cnt);
			undefine MemNode.sharers;
		case PutS:
			if cnt = 1 then
				Send(PutLast, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			else
				Send(PutAck, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			endif;
			RemoveFromSharersList(msg.src);
		case PutM:
			assert (msg.src != MemNode.owner) "PutM from owner";
			Send(PutAck, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		else
			ErrorUnhandledMsg(msg, MemType);
		endswitch;

	case M_S:
		switch msg.mtype
		case GetS:
			AddToSharersList(msg.src);
			-- existing sharers can be ignored since the data is read-only
			Send(Data, msg.src, MemType, ResponseChannel, MemNode.val, UNDEFINED, 0);
		case GetM:
			MemNode.state := M_M;
			MemNode.owner := msg.src;
			if IsSharer(msg.src) then -- don't need to wait for yourself to Ack
				Send(Data, msg.src, MemType, ResponseChannel, MemNode.val, UNDEFINED, cnt-1);
			else
				Send(Data, msg.src, MemType, ResponseChannel, MemNode.val, UNDEFINED, cnt);
			endif;
			SendInvReqToSharers(msg.src);
			undefine MemNode.sharers;
		case PutS:
			if cnt = 1
			then
				Send(PutLast, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
				MemNode.state := M_SI_A;
			else
				Send(PutAck, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			endif;
			RemoveFromSharersList(msg.src);
		case PutM:
			assert (msg.src != MemNode.owner) "PutM from owner";
			RemoveFromSharersList(msg.src);
			Send(PutAck, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		else
			ErrorUnhandledMsg(msg, MemType);
		endswitch;

	case M_M:
		assert (!IsUnDefined(MemNode.owner)) "owner undefined";
		switch msg.mtype
		case GetS:
			MemNode.state := M_S_D;
			AddToSharersList(msg.src);
			AddToSharersList(MemNode.owner);
			Send(FwdGetS, MemNode.owner, MemType, ForwardChannel, UNDEFINED, msg.src, UNDEFINED);
			undefine MemNode.owner;
		case GetM:
			Send(FwdGetM, MemNode.owner, MemType, ForwardChannel, UNDEFINED, msg.src, UNDEFINED);
			MemNode.owner := msg.src;
			MemNode.state := M_MM_A;
		case PutS:
			if cnt = 1 then
				Send(PutLast, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			else
				Send(PutAck, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			endif;
		case PutM:
			if MemNode.owner = msg.src
			then
				MemNode.val := msg.val;
				LastWrite := MemNode.val;
				undefine MemNode.owner;
				MemNode.state := M_I;
			endif;
			Send(PutAck, msg.src, MemType, ForwardChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		else
			ErrorUnhandledMsg(msg, MemType);
		endswitch;

	case M_S_D:
		switch msg.mtype
		case GetS:
			msg_processed := false;
		case GetM:
			msg_processed := false;
		case PutS:
			msg_processed := false;
		case PutM:
			msg_processed := false;
		case Data:
			MemNode.state := M_S;
			MemNode.val := msg.val;
			LastWrite := MemNode.val;
		else
			ErrorUnhandledMsg(msg, MemType);
		endswitch;

	case M_MM_A:
		switch msg.mtype
		case GetS:
			msg_processed := false;
		case GetM:
			msg_processed := false;
		case PutS:
			msg_processed := false;
		case PutM:
			msg_processed := false;
		case Data:
			msg_processed := false;
		case FwdAck:
			MemNode.state := M_M;
		else
			ErrorUnhandledMsg(msg, MemType);
		endswitch;

	case M_SI_A:
		switch msg.mtype
		case GetS:
			msg_processed := false;
		case GetM:
			msg_processed := false;
		case PutS:
			msg_processed := false;
		case PutM:
			msg_processed := false;
		case Data:
			msg_processed := false;
		case PutAck:
			msg_processed := false;
		case PutLastAck:
			MemNode.state := M_I;
		else
			ErrorUnhandledMsg(msg, MemType);
		endswitch;

	else
		ErrorUnhandledState();
	endswitch;
end;

---------------------------------------------------------------------------------

procedure ProcReceive(msg: Message; p: Proc);
begin

	put "Proc "; put p; put " receiving "; put msg.mtype; put " from "; put msg.src;  put " on VC"; put msg.vc; put " "; put Procs[p].state;

	-- default to 'processing' message.	set to false otherwise
	msg_processed := true;

	alias pstate: Procs[p].state do
	alias pval: Procs[p].val do
	alias packs_needed: Procs[p].acks_needed do
	alias packs_received: Procs[p].acks_received do

	switch pstate
	case P_I:
		-- processor shouldn't receive any messages when in Invalid state
		switch msg.mtype
		case FwdGetS:
			msg_processed := false;
		case FwdGetM:
			msg_processed := false;
		case Inv:
			Send(InvAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_IS_D:
		switch msg.mtype
		case Inv:
			Send(InvAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		case Data:
			-- double check later
			assert (msg.ack = 0) "Non-zero ACKs";
			pstate := P_S;
			pval := msg.val;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_IM_AD:
		switch msg.mtype
		case FwdGetS:
			msg_processed := false;
		case FwdGetM:
			msg_processed := false;
		case Inv:
			Send(InvAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		case Data:
			if msg.src = MemType then -- data is from directory controller
				if msg.ack = 0 then -- no sharers, we can modify
					pstate := P_M;
				else -- wait on ACKs
					if msg.ack = packs_received then -- already received OoO ACKs
						packs_needed := 0;
						packs_received := 0;
						pstate := P_M;
					else
						pstate := P_IM_A;
						packs_needed := msg.ack;
					endif;
				endif;
			else -- data is from another processor
				packs_needed := 0;
				packs_received := 0;
				pstate := P_M;
			endif;
			pval := msg.val;
		case InvAck:
			packs_received := packs_received + 1;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_IM_A:
		switch msg.mtype
		case FwdGetS:
			msg_processed := false;
		case FwdGetM:
			msg_processed := false;
		case InvAck:
			packs_received := packs_received + 1;
			if packs_received = packs_needed
			then
				packs_needed := 0;
				packs_received := 0;
				pstate := P_M;
			endif;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_S:
		switch msg.mtype
		case Inv:
			pstate := P_I;
			Send(InvAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			undefine pval;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_SM_AD:
		switch msg.mtype
		case FwdGetS:
			msg_processed := false;
		case FwdGetM:
			msg_processed := false;
		case Inv:
			pstate := P_IM_AD;
			Send(InvAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		case Data:
			if msg.src = MemType  then -- data is from directory controller
				if msg.ack = 0 then -- no sharers, we can modify
					pstate := P_M;
				else -- wait on ACKs
					if msg.ack = packs_received then -- already received OoO ACKs
						packs_needed := 0;
						packs_received := 0;
						pstate := P_M;
					else
						pstate := P_SM_A;
						packs_needed := msg.ack;
					endif;
				endif;
			else -- data is from another processor
				packs_needed := 0;
				packs_received := 0;
				pstate := P_M;
			endif;
			pval := msg.val;
		case InvAck:
			packs_received := packs_received + 1;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_SM_A:
		switch msg.mtype
		case FwdGetS:
			msg_processed := false;
		case FwdGetM:
			msg_processed := false;
		case InvAck:
			packs_received := packs_received + 1;
			if packs_received = packs_needed
			then
				packs_needed := 0;
				packs_received := 0;
				pstate := P_M;
			endif;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_M:
		switch msg.mtype
		case FwdGetS:
			pstate := P_S;
			Send(Data, MemType, p, ResponseChannel, pval, UNDEFINED, UNDEFINED);
			Send(Data, msg.who, p, ResponseChannel, pval, UNDEFINED, 0);
		case FwdGetM:
			pstate := P_I;
			Send(Data, msg.who, p, ResponseChannel, pval, UNDEFINED, 0);
			Send(FwdAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			undefine pval;
		case InvAck:
			-- do nothing
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_MI_A:
		switch msg.mtype
		case FwdGetS:
			pstate := P_SI_A;
			Send(Data, MemType, p, ResponseChannel, pval, UNDEFINED, UNDEFINED);
			Send(Data, msg.who, p, ResponseChannel, pval, UNDEFINED, 0);
		case FwdGetM:
			pstate := P_II_A;
			Send(Data, msg.who, p, ResponseChannel, pval, UNDEFINED, 0);
			Send(FwdAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		case PutAck:
			pstate := P_I;
			undefine pval;
		case InvAck:
			-- do nothing
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_SI_A:
		switch msg.mtype
		case Inv:
			pstate := P_II_A;
			Send(InvAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		case PutAck:
			pstate := P_I;
			undefine pval;
		case PutLast:
			pstate := P_I;
			Send(PutLastAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			undefine pval;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case P_II_A:
		switch msg.mtype
		case PutAck:
			pstate := P_I;
			undefine pval;
		case PutLast:
			Send(PutLastAck, msg.src, p, ResponseChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			pstate := P_I;
			undefine pval;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	else
		ErrorUnhandledState();
	endswitch;
	
	endalias;
	endalias;
	endalias;
	endalias;
end;

---------------------------------------------------------------------------------
-- Rules-------------------------------------------------------------------------
---------------------------------------------------------------------------------

-- Processor actions (affecting coherency)
ruleset n: Proc do
	alias p: Procs[n] do

	rule "Processor in Invalid state, requesting to load value"
		(p.state = P_I)
	==>
		Send(GetS, MemType, n, RequestChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		p.state := P_IS_D;
	endrule;

	ruleset v: Value do
		rule "Processor in Invalid state, requesting to store value"
			(p.state = P_I)
		==>
			Send(GetM, MemType, n, RequestChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			p.state := P_IM_AD;
		endrule;
	endruleset;

	ruleset v: Value do
		rule "Processor in Shared state, requesting to store value"
			(p.state = P_S)
		==>
			Send(GetM, MemType, n, RequestChannel, UNDEFINED, UNDEFINED, UNDEFINED);
			p.state := P_SM_AD;
		endrule;
	endruleset;

	rule "Processor in Shared state, evicting value"
		(p.state = P_S)
	==>
		Send(PutS, MemType, n, RequestChannel, UNDEFINED, UNDEFINED, UNDEFINED);
		p.state := P_SI_A;
	endrule;

	rule "Processor in Modified state, evicting value"
		(p.state = P_M)
	==>
		Send(PutM, MemType, n, RequestChannel, p.val, UNDEFINED, UNDEFINED);
		p.state := P_MI_A;
	endrule;

	endalias;
endruleset;

---------------------------------------------------------------------------------

-- Message delivery rules
ruleset n: Node do
	-- choose a random message index for this Node
	choose midx: Net[n] do
		alias chan: Net[n] do
		alias msg: chan[midx] do
		alias box: InBox[n] do

		-- Pick a random message in the network and deliver it
		rule "Receive-net"
			(isundefined(box[msg.vc].mtype))
		==>

			if IsMember(n, Mem)
			then
				MemReceive(msg);
			else
				ProcReceive(msg, n);
			endif;

			if ! msg_processed
			then
				-- The node refused the message, put in InBox to block the VC.
				box[msg.vc] := msg;
			endif;
		
			MultiSetRemove(midx, chan);
		
		endrule;
	
		endalias
		endalias;
		endalias;
	endchoose;	

	-- Try to deliver a message from a blocked VC; perhaps node can handle it now
	ruleset vc: VCType do
		rule "receive-blocked-vc"
			(! isundefined(InBox[n][vc].mtype))
		==>
			if IsMember(n, Mem)
			then
				MemReceive(InBox[n][vc]);
			else
				ProcReceive(InBox[n][vc], n);
			endif;

			if msg_processed
			then
				-- Message has been handled, forget it
				undefine InBox[n][vc];
			endif;
		
		endrule;
	endruleset;

endruleset;

---------------------------------------------------------------------------------
-- Startstate--------------------------------------------------------------------
---------------------------------------------------------------------------------
startstate

	-- mem node initialization
	For v: Value do
		MemNode.state := M_I;
		undefine MemNode.owner;
		undefine MemNode.sharers;
		MemNode.val := v;
	endfor;
	LastWrite := MemNode.val;
	
	-- processor initialization
	for i: Proc do
		Procs[i].state := P_I;
		undefine Procs[i].val;
		undefine Procs[i].acks_needed;
		Procs[i].acks_received := 0;
	endfor;

	-- network initialization
	undefine Net;
endstartstate;

---------------------------------------------------------------------------------
-- Invariants--------------------------------------------------------------------
---------------------------------------------------------------------------------

invariant "Invalid implies empty owner"
	MemNode.state = M_I
		->
			IsUndefined(MemNode.owner);

---------------------------------------------------------------------------------

invariant "Value in memory matches value of last write, when invalid"
		 MemNode.state = M_I
		->
			MemNode.val = LastWrite;

---------------------------------------------------------------------------------
	
invariant "Value is undefined while invalid"
	Forall n : Proc Do	
		 Procs[n].state = P_I
		->
			IsUndefined(Procs[n].val)
	end;
	
---------------------------------------------------------------------------------

invariant "Modified implies empty sharers list"
	MemNode.state = M_M
		->
			MultiSetCount(i: MemNode.sharers, true) = 0;

---------------------------------------------------------------------------------

invariant "Invalid implies empty sharer list"
	MemNode.state = M_I
		->
			MultiSetCount(i: MemNode.sharers, true) = 0;

---------------------------------------------------------------------------------

invariant "Values in memory matches value of last write, when shared or invalid"
	Forall n : Proc Do	
		 MemNode.state = M_S | MemNode.state = M_I
		->
			MemNode.val = LastWrite
	end;

---------------------------------------------------------------------------------

invariant "Values in shared state match memory"
	Forall n : Proc Do	
		 MemNode.state = M_S & Procs[n].state = P_S
		->
			MemNode.val = Procs[n].val
	end;
