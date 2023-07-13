// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "./LuckyDraw.sol";

contract LuckyDrawFactory {
    LuckyDraw private currentGame;

    enum GameState {
        STARTED,
        VRF_REQUESTED,
        VRF_DRAWN,
        OVER
    }

    GameState private gameState = GameState.OVER;

    struct GameInfos {
        GameState gameState;
        uint256 gameNumber;
        address gameAddress;
        uint256 ticketPrice;
        uint256 maxTicketsPerAddress;
        uint256 maxTicketsPerAddressAtOnce;
        uint256 gameStartTimestamp;
        uint256 drawInterval;
        uint8 houseFeePercent;
        uint8 numWinners;
        uint256 totalTicketsCount;
    }

    struct VRFRequests {
        uint256 id;
        uint256 blockNumber;
    }
    VRFRequests public VRFRequest;

    uint256 private ticketPrice;
    uint256 private maxTicketsPerAddress = 1000;
    uint256 private maxTicketsPerAddressAtOnce = 300;
    uint256 private drawInterval = 82800;

    address public ownerAddress;
    address public houseAddress;
    address public token;
    address public chainlinkVRF;
    bytes32 public chainlinkVRFKeyHash;

    uint64 public chainlinkVRFSubscriptionId = 0;

    uint8 private houseFeePercent = 10;
    uint8 private numWinners = 3;

    mapping(uint256 => address) public dailyDrawGames;

    using Counters for Counters.Counter;
    Counters.Counter private gamesCounter;

    event GameCreated(address indexed gameAddress, uint256 indexed gameNumber);
    event GameOver(address indexed gameAddress, uint256 indexed gameNumber);
    event ticketBuy(
        address indexed buyer,
        uint256 indexed gameNumber,
        uint256 numTickets,
        uint256 ticketPrice
    );
    event drawWinners(
        uint256 indexed gameNumber,
        address[] winners,
        uint256[] winningTicket,
        uint256 prizeVal
    );
    event VRFRequested(uint256 indexed gameNumber, uint256 indexed requestId);

    constructor(
        address _chainlinkVRF,
        bytes32 _chainlinkVRFKeyHash,
        uint64 _chainlinkVRFSubscriptionId,
        address _token,
        uint256 _ticketPrice,
        address _ownerAddress
    ) {
        token = _token;
        ticketPrice = _ticketPrice;
        ownerAddress = _ownerAddress;
        houseAddress = _ownerAddress;
        chainlinkVRF = _chainlinkVRF;
        chainlinkVRFKeyHash = _chainlinkVRFKeyHash;
        chainlinkVRFSubscriptionId = _chainlinkVRFSubscriptionId;
        createGame();
    }

    modifier onlyOwner() {
        require(
            msg.sender == ownerAddress,
            "Only owner can call this function"
        );
        _;
    }

    function createGame() private {
        require(gameState == GameState.OVER, "A Game is Already Running");
        gamesCounter.increment();
        dailyDrawGames[gamesCounter.current()] = address(
            new LuckyDraw(address(this), maxTicketsPerAddress)
        );
        currentGame = LuckyDraw(dailyDrawGames[gamesCounter.current()]);
        gameState = GameState.STARTED;
        emit GameCreated(address(currentGame), gamesCounter.current());
    }

    function buyTickets(uint numTickets) external {
        require(gameState == GameState.STARTED, "Game not started");
        require(
            numTickets > 0 && numTickets <= maxTicketsPerAddressAtOnce,
            "Must buy at least one ticket and less than maxTicketsPerAddressAtOnce"
        );
        require(
            currentGame.getUserTicketsCount(msg.sender) + numTickets <=
                maxTicketsPerAddress,
            "Cannot buy more than maxTicketsPerAddress"
        );
        require(
            IERC20(token).transferFrom(
                msg.sender,
                address(this),
                ticketPrice * numTickets
            ),
            "Transfer failed"
        );
        require(
            currentGame.buyTickets(msg.sender, numTickets),
            "can't buy ticket"
        );
        emit ticketBuy(
            msg.sender,
            gamesCounter.current(),
            numTickets,
            ticketPrice
        );
    }

    function drawWinnersRequest() external onlyOwner returns (uint256) {
        require(gameState == GameState.STARTED, "Game not started");

        require(
            block.timestamp >= currentGame.gameStartTimestamp() + drawInterval,
            "Draw interval not reached"
        );
        require(currentGame.getWinnersNumber() == 0, "Winners already drawn");

        if (currentGame.getTotalTicketsCount() <= numWinners) {
            currentGame.setGameStartTimestamp(block.timestamp);
            return 0;
        }

        uint256 requestId;
        requestId = VRFCoordinatorV2Interface(chainlinkVRF).requestRandomWords(
            chainlinkVRFKeyHash,
            chainlinkVRFSubscriptionId,
            10,
            2500000,
            1
        );

        VRFRequest = VRFRequests(requestId, block.number);
        gameState = GameState.VRF_REQUESTED;

        emit VRFRequested(gamesCounter.current(), requestId);

        return requestId;
    }

    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external {
        require(
            msg.sender == chainlinkVRF,
            "only chainlink VRF can call this function"
        );
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) private {
        require(gameState == GameState.VRF_REQUESTED, "VRF not requested");
        require(VRFRequest.id == requestId, "Wrong requestId");

        gameState = GameState.VRF_DRAWN;

        currentGame.drawWinners(randomWords, numWinners);

        sendPrizes();
    }

    function sendPrizes() private {
        require(gameState == GameState.VRF_DRAWN, "VRF not drawn");
        require(
            currentGame.getWinnersNumber() == numWinners,
            "Winners not drawn"
        );

        address[] memory winners = currentGame.getWinners();
        require(winners.length == numWinners, "Wrong number of winners");

        uint256 totalPrize = currentGame.getTotalTicketsCount() * ticketPrice;
        require(
            IERC20(token).balanceOf(address(this)) >= totalPrize,
            "Not enough balance"
        );

        uint256 houseFee = (totalPrize * houseFeePercent) / 100;
        uint256 prizePerWinner = (totalPrize - houseFee) / numWinners;

        emit drawWinners(
            gamesCounter.current(),
            winners,
            currentGame.getWinningTickets(),
            prizePerWinner
        );

        for (uint8 i = 0; i < numWinners; i++) {
            require(
                IERC20(token).transfer(winners[i], prizePerWinner),
                "Transfer failed"
            );
        }

        require(
            IERC20(token).transfer(houseAddress, houseFee),
            "Transfer failed"
        );

        gameState = GameState.OVER;
        emit GameOver(address(currentGame), gamesCounter.current());

        createGame();
    }

    function setTicketPrice(uint256 _ticketPrice) external onlyOwner {
        ticketPrice = _ticketPrice;
    }

    function setMaxTicketsPerAddress(
        uint256 _maxTicketsPerAddress
    ) external onlyOwner {
        maxTicketsPerAddress = _maxTicketsPerAddress;
    }

    function setMaxTicketsPerAddressAtOnce(
        uint _maxTicketsPerAddressAtOnce
    ) external onlyOwner {
        maxTicketsPerAddressAtOnce = _maxTicketsPerAddressAtOnce;
    }

    function setDrawInterval(uint256 _drawInterval) external onlyOwner {
        drawInterval = _drawInterval;
    }

    function setHouseFeePercent(uint8 _houseFeePercent) external onlyOwner {
        houseFeePercent = _houseFeePercent;
    }

    function setNumWinners(uint8 _numWinners) external onlyOwner {
        numWinners = _numWinners;
    }

    function setOwnerAddress(address _ownerAddress) external onlyOwner {
        ownerAddress = _ownerAddress;
    }

    function setHouseAddress(address _houseAddress) external onlyOwner {
        houseAddress = _houseAddress;
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

    function withdrawTokenFromGame(
        address _game,
        address _token,
        uint256 _amount
    ) external onlyOwner {
        LuckyDraw(_game).withdrawToken(_token, msg.sender, _amount);
    }

    function withdrawEthFromGame(
        address _game,
        uint256 _amount
    ) external onlyOwner {
        LuckyDraw(_game).withdrawETH(msg.sender, _amount);
    }

    function getCurrentGameInfo() external view returns (GameInfos memory) {
        GameInfos memory currentGameInfos;
        currentGameInfos.gameState = gameState;
        currentGameInfos.gameNumber = gamesCounter.current();
        currentGameInfos.gameAddress = dailyDrawGames[gamesCounter.current()];
        currentGameInfos.ticketPrice = ticketPrice;
        currentGameInfos.maxTicketsPerAddress = maxTicketsPerAddress;
        currentGameInfos
            .maxTicketsPerAddressAtOnce = maxTicketsPerAddressAtOnce;
        currentGameInfos.gameStartTimestamp = currentGame.gameStartTimestamp();
        currentGameInfos.drawInterval = drawInterval;
        currentGameInfos.houseFeePercent = houseFeePercent;
        currentGameInfos.numWinners = numWinners;
        currentGameInfos.totalTicketsCount = currentGame.getTotalTicketsCount();
        return currentGameInfos;
    }
}
