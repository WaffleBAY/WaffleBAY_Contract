// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title WaffleTreasury
 * @notice 4명의 팀원이 수익을 25%씩 공평하게 나눠 갖는 금고입니다.
 */
contract WaffleTreasury {
    // 팀원 4명의 지갑 주소
    address[] public payees;
    
    // 지금까지 이 컨트랙트로 들어온 총 금액
    uint256 public totalReceived;
    
    // 각 팀원이 이미 찾아간 금액 기록
    mapping(address => uint256) public totalReleased;

    event PaymentReceived(address from, uint256 amount);
    event PaymentReleased(address to, uint256 amount);

    constructor(address[] memory _payees) {
        require(_payees.length == 4, "Must provide exactly 4 payees");
        payees = _payees;
    }

    // 돈을 받는 함수 (누군가 이 주소로 ETH를 보내면 실행됨)
    receive() external payable {
        totalReceived += msg.value;
        emit PaymentReceived(msg.sender, msg.value);
    }

    // 내 몫을 인출하는 함수 (팀원 누구나 호출 가능)
    function claim() external {
        require(_isPayee(msg.sender), "You are not a payee");

        // 1인당 총 할당량 = (현재까지 들어온 돈) / 4
        uint256 totalShare = totalReceived / payees.length;
        
        // 내가 지금 찾아갈 수 있는 돈 = (총 할당량) - (이미 찾아간 돈)
        uint256 payment = totalShare - totalReleased[msg.sender];

        require(payment > 0, "Nothing to claim");

        totalReleased[msg.sender] += payment;
        
        (bool success, ) = payable(msg.sender).call{value: payment}("");
        require(success, "Transfer failed");

        emit PaymentReleased(msg.sender, payment);
    }

    // 현재 인출 가능한 잔액 조회
    function pendingPayment(address _account) external view returns (uint256) {
        if (!_isPayee(_account)) return 0;
        uint256 totalShare = totalReceived / payees.length;
        return totalShare - totalReleased[_account];
    }

    function _isPayee(address _account) internal view returns (bool) {
        for (uint i = 0; i < payees.length; i++) {
            if (payees[i] == _account) return true;
        }
        return false;
    }
}