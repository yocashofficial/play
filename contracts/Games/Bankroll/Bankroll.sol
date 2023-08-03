// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Bankroll {
    using SafeERC20 for IERC20;

    mapping(address => bool) isGame;
    mapping(address => bool) isTokenAllowed;
    mapping(address => uint256) suspendedTime;
    mapping(address => bool) suspendedPlayers;

    address public ownerAddress;
    address[] allowedTokens;

    event nativeTokenTransferFailed(address indexed player, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == ownerAddress, "Not Owner");
        _;
    }

    constructor() {
        ownerAddress = msg.sender;
    }

    function getIsValidWager(
        address game,
        address tokenAddress
    ) external view returns (bool) {
        return (isGame[game] && isTokenAllowed[tokenAddress]);
    }

    function setTokenAddress(
        address tokenAddress,
        bool isValid
    ) external onlyOwner {
        isTokenAllowed[tokenAddress] = isValid;
        allowedTokens.push(tokenAddress);
    }

    function transferPayout(
        address player,
        uint256 payout,
        address tokenAddress
    ) external {
        require(isGame[msg.sender], "Not a valid game");
        if (tokenAddress != address(0)) {
            IERC20(tokenAddress).safeTransfer(player, payout);
        } else {
            (bool success, ) = payable(player).call{value: payout, gas: 2400}(
                ""
            );
            if (!success) {
                emit nativeTokenTransferFailed(player, payout);
            }
        }
    }

    function setPlayerSuspended(
        uint256 suspensionTime,
        address _player
    ) external onlyOwner {
        require(suspendedTime[_player] > block.timestamp, "Already Suspended");
        suspendedTime[_player] = block.timestamp + suspensionTime;
        suspendedPlayers[_player] = true;
    }

    function setPlayerSuspensionTime(
        uint256 suspensionTime,
        address _player
    ) external onlyOwner {
        suspendedTime[_player] += suspensionTime;
        suspendedPlayers[_player] = true;
    }

    function setPlayerBanned(address _player) external onlyOwner {
        suspendedTime[_player] = 2 ** 256 - 1;
        suspendedPlayers[_player] = true;
    }

    function setPlayerNotSuspended(address _player) external onlyOwner {
        require(suspendedTime[_player] > block.timestamp, "Not suspended");
        suspendedPlayers[_player] = false;
    }

    function setGame(address game, bool _state) external onlyOwner {
        isGame[game] = _state;
    }

    function getIsGame(address game) external view returns (bool) {
        return isGame[game];
    }

    function getIsTokenAllowed(
        address tokenAddress
    ) external view returns (bool) {
        return isTokenAllowed[tokenAddress];
    }

    function isPlayerSuspended(
        address player
    ) external view returns (bool, uint256) {
        return (suspendedPlayers[player], suspendedTime[player]);
    }

    function viewAllowedTokens() external view returns (address[] memory) {
        return allowedTokens;
    }

    function viewOwner() external view returns (address) {
        return ownerAddress;
    }

    function withdrawToken(address _token, uint256 _amount) external onlyOwner {
        require(
            IERC20(_token).transfer(msg.sender, _amount),
            "Transfer failed"
        );
    }

    function withdrawEth(uint256 _amount) external onlyOwner {
        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        require(success, "Transfer failed");
    }

    receive() external payable {}
}
