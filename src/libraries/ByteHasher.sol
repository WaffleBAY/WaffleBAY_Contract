// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ByteHasher Library
/// @notice 문자열이나 바이트를 WorldID 호환 필드 요소로 변환
library ByteHasher {
    /// @dev Keccak256 해시 후 스칼라 필드 크기로 모듈러 연산 수행
    function hashToField(bytes memory value) internal pure returns (uint256) {
        return uint256(keccak256(value)) % 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    }
}