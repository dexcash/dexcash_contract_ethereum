// SPDX-License-Identifier: GPL
pragma solidity 0.6.12;

import "./interfaces/IDexCashToken.sol";
import "./interfaces/IDexCashGov.sol";
import "./interfaces/IDexCashFactory.sol";

contract DexCashGov is IDexCashGov {

    struct VoterInfo {
        uint24  votedProposal;
        uint8   votedOpinion;
        uint112 votedAmt;     // enouth to store DXCH
        uint112 depositedAmt; // enouth to store DXCH
    }

    uint8   private constant _PROPOSAL_TYPE_FUNDS   = 1; // ask for funds
    uint8   private constant _PROPOSAL_TYPE_PARAM   = 2; // change factory.feeBPS
    uint8   private constant _PROPOSAL_TYPE_UPGRADE = 3; // change factory.pairLogic
    uint8   private constant _PROPOSAL_TYPE_TEXT    = 4; // pure text proposal
    uint8   private constant _YES = 1;
    uint8   private constant _NO  = 2;
    uint32  private constant _MIN_FEE_BPS = 0;
    uint32  private constant _MAX_FEE_BPS = 50;
    uint256 private constant _MAX_FUNDS_REQUEST = 5000000; // 5000000 DXCH
    uint256 private constant _FAILED_PROPOSAL_COST = 1000; //    1000 DXCH
    uint256 private constant _SUBMIT_DXCH_PERCENT = 1; // 1%
    uint256 private constant _VOTE_PERIOD = 3 days;
    uint256 private constant _TEXT_PROPOSAL_INTERVAL = 1 days;

    address public  immutable override dxch;
    uint256 private immutable _maxFundsRequest;    // 5000000 DXCH
    uint256 private immutable _failedProposalCost; //    1000 DXCH

    uint24  private _proposalID;
    uint8   private _proposalType; // FUNDS            | PARAM        | UPGRADE            | TEXT
    uint32  private _deadline;     // unix timestamp   | same         | same               | same
    address private _addr;         // beneficiary addr | factory addr | factory addr       | not used
    uint256 private _value;        // amount of funds  | feeBPS       | pair logic address | not used
    address private _proposer;
    uint112 private _totalYes;
    uint112 private _totalNo;
    uint112 private _totalDeposit;
    mapping (address => VoterInfo) private _voters;

    constructor(address _dxch) public {
        dxch = _dxch;
        uint256 dxchDec = IERC20(_dxch).decimals();
        _maxFundsRequest = _MAX_FUNDS_REQUEST * (10 ** dxchDec);
        _failedProposalCost = _FAILED_PROPOSAL_COST * (10 ** dxchDec);
    }

    function proposalInfo() external view override returns (
            uint24 id, address proposer, uint8 _type, uint32 deadline, address addr, uint256 value,
            uint112 totalYes, uint112 totalNo, uint112 totalDeposit) {
        id           = _proposalID;
        proposer     = _proposer;
        _type        = _proposalType;
        deadline     = _deadline;
        value        = _value;
        addr         = _addr;
        totalYes     = _totalYes;
        totalNo      = _totalNo;
        totalDeposit = _totalDeposit;
    }
    function voterInfo(address voter) external view override returns (
            uint24 votedProposalID, uint8 votedOpinion, uint112 votedAmt, uint112 depositedAmt) {
        VoterInfo memory info = _voters[voter];
        votedProposalID = info.votedProposal;
        votedOpinion    = info.votedOpinion;
        votedAmt        = info.votedAmt;
        depositedAmt    = info.depositedAmt;
    }

    // submit new proposals
    function submitFundsProposal(string calldata title, string calldata desc, string calldata url,
            address beneficiary, uint256 fundsAmt, uint112 voteAmt) external override {
        if (fundsAmt > 0) {
            require(fundsAmt <= _maxFundsRequest, "DexCashGov: ASK_TOO_MANY_FUNDS");
            uint256 govDXCH = IERC20(dxch).balanceOf(address(this));
            uint256 availableDXCH = govDXCH - _totalDeposit;
            require(govDXCH > _totalDeposit && availableDXCH >= fundsAmt,
                "DexCashGov: INSUFFICIENT_FUNDS");
        }
        _newProposal(_PROPOSAL_TYPE_FUNDS, beneficiary, fundsAmt, voteAmt);
        emit NewFundsProposal(_proposalID, title, desc, url, _deadline, beneficiary, fundsAmt);
        _vote(_YES, voteAmt);
    }
    function submitParamProposal(string calldata title, string calldata desc, string calldata url,
            address factory, uint32 feeBPS, uint112 voteAmt) external override {
        require(feeBPS >= _MIN_FEE_BPS && feeBPS <= _MAX_FEE_BPS, "DexCashGov: INVALID_FEE_BPS");
        _newProposal(_PROPOSAL_TYPE_PARAM, factory, feeBPS, voteAmt);
        emit NewParamProposal(_proposalID, title, desc, url, _deadline, factory, feeBPS);
        _vote(_YES, voteAmt);
    }
    function submitUpgradeProposal(string calldata title, string calldata desc, string calldata url,
            address factory, address pairLogic, uint112 voteAmt) external override {
        require(pairLogic != address(0), "DexCashGov: INVALID_PAIR_LOGIC");
        _newProposal(_PROPOSAL_TYPE_UPGRADE, factory, uint256(pairLogic), voteAmt);
        emit NewUpgradeProposal(_proposalID, title, desc, url, _deadline, factory, pairLogic);
        _vote(_YES, voteAmt);
    }
    function submitTextProposal(string calldata title, string calldata desc, string calldata url,
            uint112 voteAmt) external override {
        // solhint-disable-next-line not-rely-on-time
        require(uint256(_deadline) + _TEXT_PROPOSAL_INTERVAL < block.timestamp,
            "DexCashGov: COOLING_DOWN");
        _newProposal(_PROPOSAL_TYPE_TEXT, address(0), 0, voteAmt);
        emit NewTextProposal(_proposalID, title, desc, url, _deadline);
        _vote(_YES, voteAmt);
    }

    function _newProposal(uint8 _type, address addr, uint256 value, uint112 voteAmt) private {
        require(_type >= _PROPOSAL_TYPE_FUNDS && _type <= _PROPOSAL_TYPE_TEXT,
            "DexCashGov: INVALID_PROPOSAL_TYPE");
        require(_proposalType == 0, "DexCashGov: LAST_PROPOSAL_NOT_FINISHED");

        uint256 totalDXCH = IERC20(dxch).totalSupply();
        uint256 thresDXCH = (totalDXCH/100) * _SUBMIT_DXCH_PERCENT;
        if(_type == _PROPOSAL_TYPE_UPGRADE) {
	    require(msg.sender == IDexCashToken(dxch).owner(), "DexCashGov: NOT_DXCH_OWNER");
	} else {
            require(voteAmt >= thresDXCH, "DexCashGov: VOTE_AMOUNT_TOO_LESS");
        }

        _proposalID++;
        _proposalType = _type;
        _proposer = msg.sender;
        // solhint-disable-next-line not-rely-on-time
        _deadline = uint32(block.timestamp + _VOTE_PERIOD);
        _value = value;
        _addr = addr;
        _totalYes = 0;
        _totalNo = 0;
    }
 
    function vote(uint8 opinion, uint112 voteAmt) external override {
        require(_proposalType > 0, "DexCashGov: NO_PROPOSAL");
        // solhint-disable-next-line not-rely-on-time
        require(uint256(_deadline) > block.timestamp, "DexCashGov: DEADLINE_REACHED");
        _vote(opinion, voteAmt);
    }

    function _vote(uint8 opinion, uint112 addedVoteAmt) private {
        require(_YES <= opinion && opinion <= _NO, "DexCashGov: INVALID_OPINION");
        require(addedVoteAmt > 0, "DexCashGov: ZERO_VOTE_AMOUNT");

        (uint24 currProposalID, uint24 votedProposalID,
            uint8 votedOpinion, uint112 votedAmt, uint112 depositedAmt) = _getVoterInfo();

        // cancel previous votes if opinion changed
        bool isRevote = false;
        if ((votedProposalID == currProposalID) && (votedOpinion != opinion)) {
            if (votedOpinion == _YES) {
                assert(_totalYes >= votedAmt);
                _totalYes -= votedAmt;
            } else {
                assert(_totalNo >= votedAmt);
                _totalNo -= votedAmt;
            }
            votedAmt = 0;
            isRevote = true;
        }

        // need to deposit more DXCH?
        assert(depositedAmt >= votedAmt);
        if (addedVoteAmt > depositedAmt - votedAmt) {
            uint112 moreDeposit = addedVoteAmt - (depositedAmt - votedAmt);
            depositedAmt += moreDeposit;
            _totalDeposit += moreDeposit;
            IERC20(dxch).transferFrom(msg.sender, address(this), moreDeposit);
        }

        if (opinion == _YES) {
            _totalYes += addedVoteAmt;
        } else {
            _totalNo += addedVoteAmt;
        }
        votedAmt += addedVoteAmt;
        _setVoterInfo(currProposalID, opinion, votedAmt, depositedAmt);
 
        if (isRevote) {
            emit Revote(currProposalID, msg.sender, opinion, addedVoteAmt);
        } else if (votedAmt > addedVoteAmt) {
            emit AddVote(currProposalID, msg.sender, opinion, addedVoteAmt);
        } else {
            emit NewVote(currProposalID, msg.sender, opinion, addedVoteAmt);
        }
    }
    function _getVoterInfo() private view returns (uint24 currProposalID,
            uint24 votedProposalID, uint8 votedOpinion, uint112 votedAmt, uint112 depositedAmt) {
        currProposalID = _proposalID;
        VoterInfo memory voter = _voters[msg.sender];
        depositedAmt = voter.depositedAmt;
        if (voter.votedProposal == currProposalID) {
            votedProposalID = currProposalID;
            votedOpinion = voter.votedOpinion;
            votedAmt = voter.votedAmt;
        }
    }
    function _setVoterInfo(uint24 proposalID,
            uint8 opinion, uint112 votedAmt, uint112 depositedAmt) private {
        _voters[msg.sender] = VoterInfo({
            votedProposal: proposalID,
            votedOpinion : opinion,
            votedAmt     : votedAmt,
            depositedAmt : depositedAmt
        });
    }

    function tally() external override {
        require(_proposalType > 0, "DexCashGov: NO_PROPOSAL");
        // solhint-disable-next-line not-rely-on-time
        require(uint256(_deadline) <= block.timestamp, "DexCashGov: STILL_VOTING");

        bool ok = _totalYes > _totalNo;
        uint8 _type = _proposalType;
        uint256 val = _value;
        address addr = _addr;
        address proposer = _proposer;
        _resetProposal();
        if (ok) {
            _execProposal(_type, addr, val);
        } else {
            _taxProposer(proposer);
        }
        emit TallyResult(_proposalID, ok);
    }
    function _resetProposal() private {
        _proposalType = 0;
     // _deadline     = 0; // use _deadline to check _TEXT_PROPOSAL_INTERVAL
        _value        = 0;
        _addr         = address(0);
        _proposer     = address(0);
        _totalYes     = 0;
        _totalNo      = 0;
    }
    function _execProposal(uint8 _type, address addr, uint256 val) private {
        if (_type == _PROPOSAL_TYPE_FUNDS) {
            if (val > 0) {
                IERC20(dxch).transfer(addr, val);
            }
        } else if (_type == _PROPOSAL_TYPE_PARAM) {
            IDexCashFactory(addr).setFeeBPS(uint32(val));
        } else if (_type == _PROPOSAL_TYPE_UPGRADE) {
            IDexCashFactory(addr).setPairLogic(address(val));
        }
    }
    function _taxProposer(address proposerAddr) private {
        // burn 1000 DXCH of proposer
        uint112 cost = uint112(_failedProposalCost);

        VoterInfo memory proposerInfo = _voters[proposerAddr];
        if (proposerInfo.depositedAmt < cost) { // unreachable!
            cost = proposerInfo.depositedAmt;
        }

        _totalDeposit -= cost;
        proposerInfo.depositedAmt -= cost;
        _voters[proposerAddr] = proposerInfo;

        IDexCashToken(dxch).burn(cost);
    }

    function withdrawDXCH(uint112 amt) external override {
        VoterInfo memory voter = _voters[msg.sender];

        require(_proposalType == 0 || voter.votedProposal < _proposalID, "DexCashGov: IN_VOTING");
        require(amt > 0 && amt <= voter.depositedAmt, "DexCashGov: INVALID_WITHDRAW_AMOUNT");

        _totalDeposit -= amt;
        voter.depositedAmt -= amt;
        if (voter.depositedAmt == 0) {
            delete _voters[msg.sender];
        } else {
            _voters[msg.sender] = voter;
        }
        IERC20(dxch).transfer(msg.sender, amt);
    }

}
