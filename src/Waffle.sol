// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Waffle {

    enum LotteryStatus {
        OPEN,
        CLOSED,
        CALCULATING,
        WAITING_DELIVERY,
        SHIPPED,
        COMPLETED,
        DISPUTED
    }

    struct Lottery {
        address seller;
        address winner;
        uint256 entryPrice;
        uint256 targetEntries;
        uint256 totalEntries;
        uint256 depositAmount;
        uint256 deadline;
        uint256 shippedAt;
        bytes32 secretHash;
        bytes32 randomSeed;
        LotteryStatus status;
    }

    struct Participant {
        address walletAddress;
        bytes32 nullifierHash;
    }

    mapping(uint256 => Lottery) public lotteries;
    mapping(uint256 => Participant[]) internal _participants;
    mapping(uint256 => mapping(bytes32 => bool)) public usedNullifiers;
    
    uint256 public lotteryCount;
    
    address public constant BURN_ADDRESS = address(0xdead);
    uint256 public constant DISPUTE_PERIOD = 7 days;
    uint256 public constant MIN_DEPOSIT = 0.01 ether;

    event LotteryCreated(
        uint256 indexed lotteryId, 
        address indexed seller, 
        uint256 entryPrice,
        uint256 targetEntries,
        uint256 depositAmount,
        bytes32 secretHash
    );
    
    event LotteryEntered(
        uint256 indexed lotteryId, 
        address indexed participant, 
        uint256 entryIndex,
        bytes32 nullifierHash
    );
    
    event LotteryClosed(uint256 indexed lotteryId);
    
    event WinnerSelected(
        uint256 indexed lotteryId, 
        address indexed winner,
        uint256 winnerIndex,
        bytes32 randomSeed
    );
    
    event ItemShipped(uint256 indexed lotteryId, uint256 shippedAt);
    
    event ReceivedConfirmed(
        uint256 indexed lotteryId,
        address indexed seller,
        uint256 totalPayout
    );
    
    event DisputeResolved(
        uint256 indexed lotteryId, 
        uint256 burnedAmount
    );
    
    event LotteryRefunded(
        uint256 indexed lotteryId,
        uint256 totalRefunded,
        uint256 participantCount
    );

    error InvalidStatus(LotteryStatus current, LotteryStatus expected);
    error InsufficientDeposit(uint256 sent, uint256 required);
    error InsufficientEntryFee(uint256 sent, uint256 required);
    error AlreadyParticipated(bytes32 nullifierHash);
    error NotSeller(address caller, address seller);
    error NotWinner(address caller, address winner);
    error LotteryExpired(uint256 deadline, uint256 currentTime);
    error LotteryNotExpired(uint256 deadline, uint256 currentTime);
    error DisputePeriodNotOver(uint256 canDisputeAfter, uint256 currentTime);
    error NoParticipants();
    error SellerCannotParticipate();
    error InvalidSecretKey(bytes32 providedHash, bytes32 expectedHash);
    error InvalidTargetEntries();
    error RefundFailed(address participant);

    modifier onlySeller(uint256 _lotteryId) {
        if (msg.sender != lotteries[_lotteryId].seller) {
            revert NotSeller(msg.sender, lotteries[_lotteryId].seller);
        }
        _;
    }
    
    modifier onlyWinner(uint256 _lotteryId) {
        if (msg.sender != lotteries[_lotteryId].winner) {
            revert NotWinner(msg.sender, lotteries[_lotteryId].winner);
        }
        _;
    }
    
    modifier inStatus(uint256 _lotteryId, LotteryStatus _expected) {
        if (lotteries[_lotteryId].status != _expected) {
            revert InvalidStatus(lotteries[_lotteryId].status, _expected);
        }
        _;
    }

    function createLottery(
        uint256 _entryPrice,
        uint256 _targetEntries,
        uint256 _duration,
        bytes32 _secretHash
    ) external payable returns (uint256 lotteryId) {
        if (msg.value < MIN_DEPOSIT) {
            revert InsufficientDeposit(msg.value, MIN_DEPOSIT);
        }
        
        if (_targetEntries == 0) {
            revert InvalidTargetEntries();
        }
        
        lotteryId = lotteryCount;
        lotteryCount++;
        
        lotteries[lotteryId] = Lottery({
            seller: msg.sender,
            winner: address(0),
            entryPrice: _entryPrice,
            targetEntries: _targetEntries,
            totalEntries: 0,
            depositAmount: msg.value,
            deadline: block.timestamp + _duration,
            shippedAt: 0,
            secretHash: _secretHash,
            randomSeed: bytes32(0),
            status: LotteryStatus.OPEN
        });
        
        emit LotteryCreated(
            lotteryId, 
            msg.sender, 
            _entryPrice, 
            _targetEntries, 
            msg.value,
            _secretHash
        );
    }

    function enterLottery(
        uint256 _lotteryId,
        bytes32 _nullifierHash
    ) external payable inStatus(_lotteryId, LotteryStatus.OPEN) {
        Lottery storage lottery = lotteries[_lotteryId];
        
        if (msg.sender == lottery.seller) {
            revert SellerCannotParticipate();
        }
        
        if (block.timestamp > lottery.deadline) {
            revert LotteryExpired(lottery.deadline, block.timestamp);
        }
        
        if (msg.value < lottery.entryPrice) {
            revert InsufficientEntryFee(msg.value, lottery.entryPrice);
        }
        
        if (usedNullifiers[_lotteryId][_nullifierHash]) {
            revert AlreadyParticipated(_nullifierHash);
        }
        
        usedNullifiers[_lotteryId][_nullifierHash] = true;
        _participants[_lotteryId].push(Participant({
            walletAddress: msg.sender,
            nullifierHash: _nullifierHash
        }));
        
        lottery.totalEntries++;
        
        uint256 entryIndex = lottery.totalEntries - 1;
        
        emit LotteryEntered(_lotteryId, msg.sender, entryIndex, _nullifierHash);
        
        if (lottery.totalEntries >= lottery.targetEntries) {
            lottery.status = LotteryStatus.CLOSED;
            emit LotteryClosed(_lotteryId);
        }
    }

    function pickWinner(uint256 _lotteryId, bytes32 _sellerSecret) 
        external 
        onlySeller(_lotteryId) 
    {
        Lottery storage lottery = lotteries[_lotteryId];
        
        if (lottery.status == LotteryStatus.OPEN) {
            if (block.timestamp <= lottery.deadline) {
                revert LotteryNotExpired(lottery.deadline, block.timestamp);
            }
            lottery.status = LotteryStatus.CLOSED;
            emit LotteryClosed(_lotteryId);
        } else if (lottery.status != LotteryStatus.CLOSED) {
            revert InvalidStatus(lottery.status, LotteryStatus.CLOSED);
        }
        
        if (lottery.totalEntries == 0) {
            revert NoParticipants();
        }
        
        bytes32 computedHash = keccak256(abi.encodePacked(_sellerSecret));
        if (computedHash != lottery.secretHash) {
            revert InvalidSecretKey(computedHash, lottery.secretHash);
        }
        
        lottery.status = LotteryStatus.CALCULATING;
        
        bytes32 participantSeed = _computeParticipantSeed(_lotteryId);
        
        bytes32 randomSeed = keccak256(abi.encodePacked(
            _sellerSecret,
            participantSeed,
            block.prevrandao,
            block.timestamp,
            block.number,
            lottery.totalEntries
        ));
        
        lottery.randomSeed = randomSeed;
        
        uint256 winnerIndex = uint256(randomSeed) % lottery.totalEntries;
        lottery.winner = _participants[_lotteryId][winnerIndex].walletAddress;
        
        lottery.status = LotteryStatus.WAITING_DELIVERY;
        
        emit WinnerSelected(_lotteryId, lottery.winner, winnerIndex, randomSeed);
    }

    function markShipped(uint256 _lotteryId) 
        external 
        onlySeller(_lotteryId) 
        inStatus(_lotteryId, LotteryStatus.WAITING_DELIVERY) 
    {
        Lottery storage lottery = lotteries[_lotteryId];
        
        lottery.shippedAt = block.timestamp;
        lottery.status = LotteryStatus.SHIPPED;
        
        emit ItemShipped(_lotteryId, lottery.shippedAt);
    }

    function confirmReceived(uint256 _lotteryId) 
        external 
        onlyWinner(_lotteryId) 
        inStatus(_lotteryId, LotteryStatus.SHIPPED) 
    {
        Lottery storage lottery = lotteries[_lotteryId];
        
        lottery.status = LotteryStatus.COMPLETED;
        
        uint256 totalCollected = lottery.entryPrice * lottery.totalEntries;
        uint256 totalPayout = totalCollected + lottery.depositAmount;
        
        (bool success, ) = lottery.seller.call{value: totalPayout}("");
        require(success, "Transfer to seller failed");
        
        emit ReceivedConfirmed(_lotteryId, lottery.seller, totalPayout);
    }

    function claimDispute(uint256 _lotteryId) 
        external 
        onlySeller(_lotteryId) 
        inStatus(_lotteryId, LotteryStatus.SHIPPED) 
    {
        Lottery storage lottery = lotteries[_lotteryId];
        
        uint256 canDisputeAfter = lottery.shippedAt + DISPUTE_PERIOD;
        if (block.timestamp < canDisputeAfter) {
            revert DisputePeriodNotOver(canDisputeAfter, block.timestamp);
        }
        
        lottery.status = LotteryStatus.DISPUTED;
        
        uint256 totalCollected = lottery.entryPrice * lottery.totalEntries;
        uint256 totalBurned = totalCollected + lottery.depositAmount;
        
        (bool success, ) = BURN_ADDRESS.call{value: totalBurned}("");
        require(success, "Burn transfer failed");
        
        emit DisputeResolved(_lotteryId, totalBurned);
    }

    function refundAll(uint256 _lotteryId) 
        external 
        onlySeller(_lotteryId)
    {
        Lottery storage lottery = lotteries[_lotteryId];
        
        if (lottery.status != LotteryStatus.OPEN && lottery.status != LotteryStatus.CLOSED) {
            revert InvalidStatus(lottery.status, LotteryStatus.OPEN);
        }
        
        if (lottery.status == LotteryStatus.OPEN) {
            if (block.timestamp <= lottery.deadline) {
                revert LotteryNotExpired(lottery.deadline, block.timestamp);
            }
        }
        
        lottery.status = LotteryStatus.DISPUTED;
        
        uint256 participantCount = _participants[_lotteryId].length;
        uint256 totalRefunded = 0;
        
        for (uint256 i = 0; i < participantCount; i++) {
            address participant = _participants[_lotteryId][i].walletAddress;
            (bool success, ) = participant.call{value: lottery.entryPrice}("");
            if (!success) {
                revert RefundFailed(participant);
            }
            totalRefunded += lottery.entryPrice;
        }
        
        (bool sellerRefund, ) = lottery.seller.call{value: lottery.depositAmount}("");
        require(sellerRefund, "Seller deposit refund failed");
        
        emit LotteryRefunded(_lotteryId, totalRefunded, participantCount);
    }

    function _computeParticipantSeed(uint256 _lotteryId) internal view returns (bytes32) {
        bytes32 seed = bytes32(0);
        uint256 count = _participants[_lotteryId].length;
        
        for (uint256 i = 0; i < count; i++) {
            seed = keccak256(abi.encodePacked(
                seed,
                _participants[_lotteryId][i].nullifierHash
            ));
        }
        
        return seed;
    }

    function getLottery(uint256 _lotteryId) external view returns (Lottery memory) {
        return lotteries[_lotteryId];
    }

    function getParticipantCount(uint256 _lotteryId) external view returns (uint256) {
        return _participants[_lotteryId].length;
    }

    function getParticipant(uint256 _lotteryId, uint256 _index) 
        external 
        view 
        returns (Participant memory) 
    {
        return _participants[_lotteryId][_index];
    }

    function getAllParticipants(uint256 _lotteryId) 
        external 
        view 
        returns (Participant[] memory) 
    {
        return _participants[_lotteryId];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    function getDisputeTime(uint256 _lotteryId) external view returns (uint256) {
        Lottery memory lottery = lotteries[_lotteryId];
        if (lottery.shippedAt == 0) return 0;
        return lottery.shippedAt + DISPUTE_PERIOD;
    }
    
    function isNullifierUsed(uint256 _lotteryId, bytes32 _nullifierHash) 
        external 
        view 
        returns (bool) 
    {
        return usedNullifiers[_lotteryId][_nullifierHash];
    }
    
    function getLotteryStatus(uint256 _lotteryId) external view returns (LotteryStatus) {
        return lotteries[_lotteryId].status;
    }
    
    function getTimeRemaining(uint256 _lotteryId) external view returns (uint256) {
        Lottery memory lottery = lotteries[_lotteryId];
        if (block.timestamp >= lottery.deadline) return 0;
        return lottery.deadline - block.timestamp;
    }
}