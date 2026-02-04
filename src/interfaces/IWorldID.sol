// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title WorldID Interface
/// @notice Worldcoin IDKit 검증을 위한 인터페이스
interface IWorldID {
    /// @dev WorldID 증명을 검증합니다.
    /// @param root Merkle root
    /// @param groupId 그룹 ID (보통 1)
    /// @param signalHash 사용자의 신호 해시
    /// @param nullifierHash 중복 방지용 Nullifier 해시
    /// @param externalNullifierHash 앱/액션 ID 해시
    /// @param proof ZK-SNARK 증명 (uint256[8])
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external view;
}