// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Counters.sol";

interface IERC20 {
    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

contract LuckyDraw {
    uint256 private maxTicketsPerAddress;
    uint256 public gameStartTimestamp;

    address private ownerAddress;

    mapping(uint256 => address) private tickets;
    mapping(address => uint256[]) private userTickets;

    address[] public winners;
    uint256[] public winningTickets;

    using Counters for Counters.Counter;
    Counters.Counter private totalTicketsCount;

    constructor(address _ownerAddress, uint256 _maxTicketsPerAddress) {
        ownerAddress = _ownerAddress;
        maxTicketsPerAddress = _maxTicketsPerAddress;
        gameStartTimestamp = block.timestamp;
    }

    modifier onlyOwner() {
        require(
            msg.sender == ownerAddress,
            "Only owner can call this function"
        );
        _;
    }

    function buyTickets(
        address _ticketHolder,
        uint _numTickets
    ) external onlyOwner returns (bool) {
        for (uint256 i = 0; i < _numTickets; i++) {
            tickets[totalTicketsCount.current()] = _ticketHolder;
            userTickets[_ticketHolder].push(totalTicketsCount.current());
            totalTicketsCount.increment();
        }
        return true;
    }

    function drawWinners(
        uint256[] memory _randomWords,
        uint8 _numWinners
    ) external onlyOwner {
        uint256 _ticket0;
        uint256 _ticketN;
        uint256 _totalTicketsCount = totalTicketsCount.current();
        _ticket0 = _randomWords[0] % _totalTicketsCount;
        winners.push(tickets[_ticket0]);
        winningTickets.push(_ticket0);
        for (uint256 i = 1; i < _numWinners; i++) {
            _ticketN =
                (_ticket0 +
                    ((_randomWords[0] % (_totalTicketsCount - i)) + i)) %
                _totalTicketsCount;
            winners.push(tickets[_ticketN]);
            winningTickets.push(_ticketN);
        }
    }

    function setGameStartTimestamp(
        uint256 _gameStartTimestamp
    ) external onlyOwner {
        gameStartTimestamp = _gameStartTimestamp;
    }

    function getTicketHolder(
        uint256 _ticketNumber
    ) external view returns (address) {
        return tickets[_ticketNumber];
    }

    function getUserTickets(
        address _userAddress
    ) external view returns (uint256[] memory) {
        return userTickets[_userAddress];
    }

    function getUserTicketsCount(
        address _userAddress
    ) external view returns (uint256) {
        return userTickets[_userAddress].length;
    }

    function getTotalTicketsCount() external view returns (uint256) {
        return totalTicketsCount.current();
    }

    function getWinners() external view returns (address[] memory) {
        return winners;
    }

    function getWinningTickets() external view returns (uint256[] memory) {
        return winningTickets;
    }

    function getWinnersNumber() external view returns (uint256) {
        return winners.length;
    }

    function withdrawToken(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(IERC20(_token).transfer(_to, _amount), "Transfer failed");
    }

    function withdrawETH(address _to, uint256 _amount) external onlyOwner {
        (bool success, ) = payable(_to).call{value: _amount}("");
        require(success, "Transfer failed");
    }
}
