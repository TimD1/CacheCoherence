
-- standard MSI protocol

---------------------------------------------------------------------------------
-- Constants---------------------------------------------------------------------
---------------------------------------------------------------------------------
const
	ProcCount: 3;			-- number processors
	ValueCount:	 2;			-- number of data values
	VC0: 0;					-- low priority virtual channel
	VC1: 1;					-- high priority virtual channel
	NumVCs: VC1 - VC0 + 1;
	NetMax: ProcCount+1;
	

---------------------------------------------------------------------------------
-- Types-------------------------------------------------------------------------
---------------------------------------------------------------------------------
type
	Proc: scalarset(ProcCount);	  	-- unordered range of processors
	Value: scalarset(ValueCount); 	-- arbitrary values for tracking coherence
	Mem: enum { MemType };	  		-- need enumeration for IsMember calls
	Node: union { Mem , Proc };

	VCType: VC0..NumVCs-1;

	-- define enum for message types
	MessageType: enum {	 
		ReadReq,				 -- request for data / exclusivity
		ReadAck,				 -- read ack (w/ data)
		WBReq,					 -- writeback request (w/ data)
		WBAck,					 -- writeback ack 
		RecallReq				 -- Request & invalidate a valid copy
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
		End;

	MemState:
		Record
			state: enum { 
				M_Valid, 					 --stable states
				M_Invalid,
				MT_Pending                   -- transient
			};
			owner: Node;	
			--sharers: multiset [ProcCount] of Node;		
			--No need for sharers, but this is a good way to represent them
			val: Value; 
		End;

	ProcState:
		Record
			state: enum { 
				P_Valid, 
				P_Invalid,
				PT_Pending, 
				PT_WritebackPending
			};
			val: Value;
		End;

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
-- Procedures--------------------------------------------------------------------
---------------------------------------------------------------------------------
Procedure Send(mtype: MessageType;
				 dst: Node;
				 src: Node;
				 vc: VCType;
				 val: Value;
			 );
var msg: Message;
Begin
	Assert (MultiSetCount(i: Net[dst], true) < NetMax) "Too many messages";
	msg.mtype:= mtype;
	msg.src	 := src;
	msg.vc	 := vc;
	msg.val	 := val;
	MultiSetAdd(msg, Net[dst]);
End;

---------------------------------------------------------------------------------

Procedure ErrorUnhandledMsg(msg: Message; n: Node);
Begin
	error "Unhandled message type!";
End;

---------------------------------------------------------------------------------

Procedure ErrorUnhandledState();
Begin
	error "Unhandled state!";
End;

/*
-- These aren't needed for Valid/Invalid protocol, 
-- but this is a good way of writing these functions
Procedure AddToSharersList(n:Node);
Begin
	if MultiSetCount(i:MemNode.sharers, MemNode.sharers[i] = n) = 0
	then
		MultiSetAdd(n, MemNode.sharers);
	endif;
End;

---------------------------------------------------------------------------------

Function IsSharer(n:Node) : Boolean;
Begin
	return MultiSetCount(i:MemNode.sharers, MemNode.sharers[i] = n) > 0
End;

---------------------------------------------------------------------------------

Procedure RemoveFromSharersList(n:Node);
Begin
	MultiSetRemovePred(i:MemNode.sharers, MemNode.sharers[i] = n);
End;

---------------------------------------------------------------------------------

-- Sends a message to all sharers except rqst
Procedure SendInvReqToSharers(rqst:Node);
Begin
	for n:Node do
		if (IsMember(n, Proc) &
				MultiSetCount(i:MemNode.sharers, MemNode.sharers[i] = n) != 0)
		then
			if n != rqst
			then 
				-- Send invalidation message here 
			endif;
		endif;
	endfor;
End;
*/

---------------------------------------------------------------------------------

-- memory controller is receiving a message
Procedure MemReceive(msg: Message);
var cnt: 0..ProcCount;	-- for counting sharers
Begin
-- Debug output may be helpful:
--	put "Receiving "; put msg.mtype; put " on VC"; put msg.vc; 
--	put " at mem -- "; put MemNode.state;

	-- The line below is not needed in Valid/Invalid protocol.	However, the 
	-- compiler barfs if we put this inside a switch, so it is useful to
	-- pre-calculate the sharer count here
	--cnt := MultiSetCount(i:MemNode.sharers, true);


	-- default to 'processing' message.	set to false otherwise
	msg_processed := true;

	switch MemNode.state
	case M_Invalid: -- memory unused by processors

		switch msg.mtype
		case ReadReq: -- reading is really the only valid operation
			MemNode.state := M_Valid;
			MemNode.owner := msg.src;
			Send(ReadAck, msg.src, MemType, VC1, MemNode.val);

		else
			ErrorUnhandledMsg(msg, MemType);

		endswitch;

	case M_Valid: -- a processor already owns the data
	    -- make sure we know who owns the data
		Assert (IsUndefined(MemNode.owner) = false) 
			 "MemNode has no owner, but line is Valid";

		switch msg.mtype
		case ReadReq: -- we'll need to switch who owns the data
			MemNode.state := MT_Pending;		 
			Send(RecallReq, MemNode.owner, MemType, VC0, UNDEFINED);
			MemNode.owner := msg.src; --remember who the new owner will be
						
		case WBReq: -- processor giving up ownership
			assert (msg.src = MemNode.owner) "Writeback from non-owner";
			MemNode.state := M_Invalid;
			MemNode.val := msg.val;
			Send(WBAck, msg.src, MemType, VC1, UNDEFINED);
			undefine MemNode.owner

		else
			ErrorUnhandledMsg(msg, MemType);

		endswitch;

	case MT_Pending: -- read was requested, but someone else owned it
		switch msg.mtype
	 
		case WBReq:  -- we've retrieved the data from the proc which owned it
			Assert (!IsUnDefined(MemNode.owner)) "owner undefined";
			MemNode.state := M_Valid;
			MemNode.val := msg.val;
			Send(ReadAck, MemNode.owner, MemType, VC1, MemNode.val);

		case ReadReq:
			msg_processed := false; -- stall message in InBox

		else
			ErrorUnhandledMsg(msg, MemType);

		endswitch;
	endswitch;
End;

---------------------------------------------------------------------------------

Procedure ProcReceive(msg: Message; p: Proc);
Begin
--	put "Receiving "; put msg.mtype; put " on VC"; put msg.vc; 
--	put " at proc "; put p; put "\n";

	-- default to 'processing' message.	set to false otherwise
	msg_processed := true;

	alias ps: Procs[p].state do
	alias pv: Procs[p].val do

	switch ps
	case P_Valid:

		switch msg.mtype
		case RecallReq:
			Send(WBReq, msg.src, p, VC1, pv);
			Undefine pv;
			ps := P_Invalid;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	case PT_Pending:

		switch msg.mtype
		case ReadAck:
			pv := msg.val;
			ps := P_Valid;
		case RecallReq:
			msg_processed := false; -- stall message in InBox
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;


	case PT_WritebackPending:		

		switch msg.mtype
		case WBAck:
			ps := P_Invalid;
			undefine pv;
		case RecallReq:	-- treat a recall request as a Writeback acknowledgement
			ps := P_Invalid;
			undefine pv;
		else
			ErrorUnhandledMsg(msg, p);
		endswitch;

	-- Error catch
	else
		ErrorUnhandledState();

	endswitch;
	
	endalias;
	endalias;
End;

---------------------------------------------------------------------------------
-- Rules-------------------------------------------------------------------------
---------------------------------------------------------------------------------

-- Processor actions (affecting coherency)
ruleset n: Proc Do
	alias p: Procs[n] Do

	-- any processor can decide to store any value
	ruleset v: Value Do
		rule "store new value"
			(p.state = P_Valid)
			==>
				p.val := v;			
				LastWrite := v;	--ensure reads receive value of last write
		endrule;
	endruleset;

	-- any processor can decide to read
	rule "read request"
		p.state = P_Invalid 
	==>
		Send(ReadReq, MemType, n, VC0, UNDEFINED);
		p.state := PT_Pending;
	endrule;

	-- any processor can write back data
	rule "writeback"
		(p.state = P_Valid)
	==>
		Send(WBReq, MemType, n, VC1, p.val); 
		p.state := PT_WritebackPending;
		undefine p.val;
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
		rule "receive-net"
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
		MemNode.state := M_Invalid;
		undefine MemNode.owner;
		MemNode.val := v;
	endfor;
	LastWrite := MemNode.val;
	
	-- processor initialization
	for i: Proc do
		Procs[i].state := P_Invalid;
		undefine Procs[i].val;
	endfor;

	-- network initialization
	undefine Net;
endstartstate;

---------------------------------------------------------------------------------
-- Invariants--------------------------------------------------------------------
---------------------------------------------------------------------------------

invariant "Invalid implies empty owner"
	MemNode.state = M_Invalid
		->
			IsUndefined(MemNode.owner);

---------------------------------------------------------------------------------

invariant "value in memory matches value of last write, when invalid"
		 MemNode.state = M_Invalid 
		->
			MemNode.val = LastWrite;

---------------------------------------------------------------------------------

invariant "values in valid state match last write"
	Forall n : Proc Do	
		 Procs[n].state = P_Valid
		->
			Procs[n].val = LastWrite --LastWrite updated when new value created 
	end;

---------------------------------------------------------------------------------
	
invariant "value is undefined while invalid"
	Forall n : Proc Do	
		 Procs[n].state = P_Invalid
		->
			IsUndefined(Procs[n].val)
	end;
	
---------------------------------------------------------------------------------

/*	
-- Here are some invariants that are helpful for validating shared state.

invariant "modified implies empty sharers list"
	MemNode.state = M_Modified
		->
			MultiSetCount(i:MemNode.sharers, true) = 0;

---------------------------------------------------------------------------------

invariant "Invalid implies empty sharer list"
	MemNode.state = M_Invalid
		->
			MultiSetCount(i:MemNode.sharers, true) = 0;

---------------------------------------------------------------------------------

invariant "values in memory matches value of last write, when shared or invalid"
	Forall n : Proc Do	
		 MemNode.state = M_Shared | MemNode.state = M_Invalid
		->
			MemNode.val = LastWrite
	end;

---------------------------------------------------------------------------------

invariant "values in shared state match memory"
	Forall n : Proc Do	
		 MemNode.state = M_Shared & Procs[n].state = P_Shared
		->
			MemNode.val = Procs[n].val
	end;
*/	
