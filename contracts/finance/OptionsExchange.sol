pragma solidity >=0.6.0;

import "../deployment/Deployer.sol";
import "../deployment/ManagedContract.sol";
import "../governance/ProtocolSettings.sol";
import "../utils/ERC20.sol";
import "../interfaces/TimeProvider.sol";
import "../interfaces/UnderlyingFeed.sol";
import "../utils/Arrays.sol";
import "../utils/MoreMath.sol";
import "../utils/SafeCast.sol";
import "../utils/SafeMath.sol";
import "../utils/SignedSafeMath.sol";
import "./CreditProvider.sol";
import "./OptionToken.sol";
import "./OptionTokenFactory.sol";

contract OptionsExchange is ManagedContract {

    using SafeCast for uint;
    using SafeMath for uint;
    using SignedSafeMath for int;
    
    enum OptionType { CALL, PUT }
    
    struct OrderData {
        uint64 id;
        OptionData option;
        address owner;
        address udlFeed;
        uint120 lowerVol;
        uint120 upperVol;
        uint120 written;
        uint120 holding;
    }
    
    struct OptionData {
        OptionType _type;
        uint120 strike;
        uint32 maturity;
    }
    
    TimeProvider private time;
    ProtocolSettings private settings;
    CreditProvider private creditProvider;
    OptionTokenFactory private factory;

    mapping(uint => OrderData) private orders;
    mapping(address => uint64[]) private book;
    mapping(address => mapping(string => uint64)) private index;

    mapping(string => address) private tokenAddress;
    mapping(string => uint64[]) private tokenIds;
    
    uint64 private serial;
    uint private volumeBase;
    uint private timeBase;
    uint private sqrtTimeBase;

    mapping(address => uint) public nonces;
    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    event CreateSymbol(string indexed symbol);

    event WriteOptions(string indexed symbol, address indexed issuer, uint volume, uint id);

    event LiquidateSymbol(string indexed symbol, int udlPrice, uint value);

    constructor(address deployer) public {

        string memory _name = "OptionsExchange";
        Deployer(deployer).setContractAddress(_name);

        uint chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(_name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function initialize(Deployer deployer) override internal {

        time = TimeProvider(deployer.getContractAddress("TimeProvider"));
        creditProvider = CreditProvider(deployer.getContractAddress("CreditProvider"));
        settings = ProtocolSettings(deployer.getContractAddress("ProtocolSettings"));
        factory = OptionTokenFactory(deployer.getContractAddress("OptionTokenFactory"));

        serial = 1;
        volumeBase = 1e18;
        timeBase = 1e18;
        sqrtTimeBase = 1e9;
    }

    function depositTokens(
        address to,
        address token,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        ERC20(token).permit(msg.sender, address(this), value, deadline, v, r, s);
        depositTokens(to, token, value);
    }

    function depositTokens(address to, address token, uint value) public {

        ERC20 t = ERC20(token);
        t.transferFrom(msg.sender, address(this), value);
        t.approve(address(creditProvider), value);
        creditProvider.depositTokens(to, token, value);
    }

    function balanceOf(address owner) external view returns (uint) {

        return creditProvider.balanceOf(owner);
    }

    function transferBalance(
        address from, 
        address to, 
        uint value,
        uint maxValue,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        require(maxValue > value, "insufficient permit value");
        permit(from, to, maxValue, deadline, v, r, s);
        creditProvider.transferBalance(from, to, value);
        ensureFunds(from);
    }

    function transferBalance(address to, uint value) public {

        creditProvider.transferBalance(msg.sender, to, value);
        ensureFunds(msg.sender);
    }
    
    function withdrawTokens(uint value) external {
        
        require(value <= calcSurplus(msg.sender), "insufficient surplus");
        creditProvider.withdrawTokens(msg.sender, value);
    }

    function writeOptions(
        address udlFeed,
        uint volume,
        OptionType optType,
        uint strike, 
        uint maturity
    )
        external 
        returns (uint id)
    {
        id = createOrder(udlFeed, volume, optType, strike, maturity);
        ensureFunds(msg.sender);
    }

    function writtenVolume(string calldata symbol, address owner) external view returns (uint) {

        return uint(findOrder(owner, symbol).written);
    }

    function transferOwnership(
        string calldata symbol,
        address from,
        address to,
        uint volume
    )
        external
    {
        require(tokenAddress[symbol] == msg.sender, "unauthorized ownership transfer");

        OrderData memory ord = findOrder(from, symbol);

        require(isValid(ord), "order not found");
        require(volume <= ord.holding, "invalid volume");
                
        OrderData memory toOrd = findOrder(to, symbol);

        if (!isValid(toOrd)) {
            toOrd = orders[ord.id];
            toOrd.id = serial++;
            toOrd.owner = address(to);
            toOrd.written = 0;
            toOrd.holding = volume.toUint120();
            orders[toOrd.id] = toOrd;
            book[to].push(toOrd.id);
            index[to][symbol] = toOrd.id;
            tokenIds[symbol].push(toOrd.id);
        } else {
            orders[toOrd.id].holding = uint(orders[toOrd.id].holding).add(volume).toUint120();
        }
        
        orders[ord.id].holding = uint(orders[ord.id].holding).sub(volume).toUint120();

        ensureFunds(ord.owner);

        if (shouldRemove(ord.id)) {
            removeOrder(symbol, ord.id);
        }
    }

    function burnOptions(
        string calldata symbol,
        address owner,
        uint volume
    )
        external
    {
        require(tokenAddress[symbol] == msg.sender, "unauthorized burn");
        
        OrderData memory ord = findOrder(owner, symbol);
        
        require(isValid(ord), "order not found");
        require(ord.written >= volume && ord.holding >= volume, "invalid volume");
        
        orders[ord.id].written = uint(ord.written).sub(volume).toUint120();
        orders[ord.id].holding = uint(ord.holding).sub(volume).toUint120();

        if (shouldRemove(ord.id)) {
            removeOrder(symbol, ord.id);
        }
    }

    function liquidateSymbol(string calldata symbol, uint limit) external {

        uint value;
        int udlPrice;
        uint iv;
        uint len = tokenIds[symbol].length;
        OrderData memory ord;

        if (len > 0) {

            for (uint i = 0; i < len && i < limit; i++) {
                
                uint64 id = tokenIds[symbol][0];
                ord = orders[id];

                if (i == 0) {
                    udlPrice = getUdlPrice(ord);
                    uint _now = getUdlNow(ord);
                    iv = uint(calcIntrinsicValue(ord));
                    require(ord.option.maturity <= _now, "maturity not reached");
                }

                require(ord.id == id, "invalid order id");

                if (ord.written > 0) {
                    value.add(
                        liquidateAfterMaturity(ord, symbol, msg.sender, iv.mul(ord.written))
                    );
                } else {
                    removeOrder(symbol, id);
                }
            }
        }

        if (len <= limit) {
            delete tokenIds[symbol];
            delete tokenAddress[symbol];
        }

        emit LiquidateSymbol(symbol, udlPrice, value);
    }

    function liquidateOptions(uint id) external returns (uint value) {
        
        OrderData memory ord = orders[id];
        require(ord.id == id && ord.written > 0, "invalid order id");

        address token = resolveToken(id);
        string memory symbol = OptionToken(token).symbol();
        uint iv = uint(calcIntrinsicValue(ord)).mul(ord.written);
        
        if (getUdlNow(ord) >= ord.option.maturity) {
            value = liquidateAfterMaturity(ord, symbol, token, iv);
        } else {
            value = liquidateBeforeMaturity(ord, symbol, token, iv);
        }
    }

    function calcDebt(address owner) external view returns (uint debt) {

        debt = creditProvider.calcDebt(owner);
    }
    
    function calcSurplus(address owner) public view returns (uint) {
        
        uint collateral = calcCollateral(owner);
        uint bal = creditProvider.balanceOf(owner);
        if (bal >= collateral) {
            return bal.sub(collateral);
        }
        return 0;
    }

    function calcCollateral(
        address udlFeed,
        uint volume,
        OptionType optType,
        uint strike, 
        uint maturity
    )
        external
        view
        returns (uint)
    {
        OrderData memory ord = createOrderInMemory(udlFeed, volume, optType, strike, maturity);

        int collateral = calcIntrinsicValue(ord).mul(int(volume)).add(
            int(calcCollateral(ord.upperVol, ord))
        ).div(int(volumeBase));

        return collateral > 0 ? uint(collateral) : 0;
    }
    
    function calcCollateral(address owner) public view returns (uint) {
        
        int collateral;
        uint64[] memory ids = book[owner];

        for (uint i = 0; i < ids.length; i++) {

            OrderData memory ord = orders[ids[i]];

            if (isValid(ord)) {
                collateral = collateral.add(
                    calcIntrinsicValue(ord).mul(
                        int(ord.written).sub(int(ord.holding))
                    )
                ).add(int(calcCollateral(ord.upperVol, ord)));
            }
        }

        collateral = collateral.div(int(volumeBase));

        if (collateral < 0)
            return 0;
        return uint(collateral);
    }

    function calcExpectedPayout(address owner) external view returns (int payout) {

        uint64[] memory ids = book[owner];

        for (uint i = 0; i < ids.length; i++) {

            OrderData memory ord = orders[ids[i]];

            if (isValid(ord)) {
                payout = payout.add(
                    calcIntrinsicValue(ord).mul(
                        int(ord.holding).sub(int(ord.written))
                    )
                );
            }
        }

        payout = payout.div(int(volumeBase));
    }

    function resolveSymbol(uint id) external view returns (string memory) {
        
        return getOptionSymbol(orders[id]);
    }

    function resolveToken(uint id) public view returns (address) {
        
        address addr = tokenAddress[getOptionSymbol(orders[id])];
        require(addr != address(0), "token not found");
        return addr;
    }

    function resolveToken(string memory symbol) public view returns (address) {
        
        address addr = tokenAddress[symbol];
        require(addr != address(0), "token not found");
        return addr;
    }

    function getBook(address owner)
        external view
        returns (
            string memory symbols,
            uint[] memory holding,
            uint[] memory written,
            int[] memory iv
        )
    {
        uint64[] memory ids = book[owner];
        holding = new uint[](ids.length);
        written = new uint[](ids.length);
        iv = new int[](ids.length);

        for (uint i = 0; i < ids.length; i++) {
            OrderData memory ord = orders[ids[i]];
            if (i == 0) {
                symbols = getOptionSymbol(ord);
            } else {
                symbols = string(abi.encodePacked(symbols, "\n", getOptionSymbol(ord)));
            }
            holding[i] = ord.holding;
            written[i] = ord.written;
            iv[i] = calcIntrinsicValue(ord);
        }
    }

    function getBookLength() external view returns (uint len) {
        
        for (uint i = 0; i < serial; i++) {
            if (isValid(orders[i])) {
                len++;
            }
        }
    }

    function getVolumeBase() external view returns (uint) {
        
        return volumeBase;
    }
    
    function calcLowerCollateral(uint id) external view returns (uint) {
        
        return calcCollateral(orders[id].lowerVol, orders[id]).div(volumeBase);
    }
    
    function calcUpperCollateral(uint id) external view returns (uint) {
        
        return calcCollateral(orders[id].upperVol, orders[id]).div(volumeBase);
    }
    
    function calcIntrinsicValue(uint id) external view returns (int) {
        
        return calcIntrinsicValue(orders[id]);
    }

    function calcIntrinsicValue(
        address udlFeed,
        OptionType optType,
        uint strike, 
        uint maturity
    )
        external
        view
        returns (int)
    {
        OrderData memory ord = createOrderInMemory(udlFeed, volumeBase, optType, strike, maturity);

        return calcIntrinsicValue(ord);
    }

    function permit(
        address from,
        address to,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        private
    {
        require(deadline >= block.timestamp, "permit expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(PERMIT_TYPEHASH, from, to, value, nonces[from]++, deadline)
                )
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == from, "invalid signature");
    }

    function createOrder(
        address udlFeed,
        uint volume,
        OptionType optType,
        uint strike, 
        uint maturity
    )
        private 
        returns (uint id)
    {
        require(udlFeed == address(0) || settings.getUdlFeed(udlFeed) > 0, "feed not allowed");
        require(volume > 0, "invalid volume");
        require(maturity > time.getNow(), "invalid maturity");

        OrderData memory ord = createOrderInMemory(udlFeed, volume, optType, strike, maturity);
        string memory symbol = getOptionSymbol(ord);

        OrderData memory result = findOrder(msg.sender, symbol);
        if (isValid(result)) {
            id = result.id;
            orders[id].written = uint(result.written).add(volume).toUint120();
            orders[id].holding = uint(result.holding).add(volume).toUint120();
        } else {
            id = serial++;
            ord.id = uint64(id);
            orders[id] = ord;
            book[msg.sender].push(ord.id);
            index[msg.sender][symbol] = ord.id;
            tokenIds[symbol].push(ord.id);
        }

        address tk = tokenAddress[symbol];
        if (tk == address(0)) {
            tk = factory.create(symbol);
            tokenAddress[symbol] = tk;
            emit CreateSymbol(symbol);
        }
        
        OptionToken(tk).issue(msg.sender, volume);
        emit WriteOptions(symbol, msg.sender, volume, id);
    }

    function createOrderInMemory(
        address udlFeed,
        uint volume,
        OptionType optType,
        uint strike, 
        uint maturity
    )
        private
        view
        returns (OrderData memory ord)
    {
        OptionData memory opt = OptionData(optType, strike.toUint120(), maturity.toUint32());

        UnderlyingFeed feed = udlFeed != address(0) ?
            UnderlyingFeed(udlFeed) :
            UnderlyingFeed(settings.getDefaultUdlFeed());

        uint vol = feed.getDailyVolatility(settings.getVolatilityPeriod());

        ord = OrderData(
            0,
            opt,
            msg.sender, 
            address(feed),
            feed.calcLowerVolatility(uint(vol)).toUint120(),
            feed.calcUpperVolatility(uint(vol)).toUint120(),
            volume.toUint120(),
            volume.toUint120()
        );
    }

    function findOrder(
        address owner,
        string memory symbol
    )
        private
        view
        returns (OrderData memory)
    {
        uint64 id = index[owner][symbol];
        if (id > 0) {
            return orders[id];
        }
    }

    function liquidateAfterMaturity(
        OrderData memory ord,
        string memory symbol,
        address token,
        uint iv
    )
        private
        returns (uint value)
    {
        if (iv > 0) {
            value = iv.div(volumeBase);
            creditProvider.processPayment(ord.owner, token, value);
        }
    
        removeOrder(symbol, ord.id);
    }

    function liquidateBeforeMaturity(
        OrderData memory ord,
        string memory symbol,
        address token,
        uint iv
    )
        private
        returns (uint value)
    {
        uint volume = calcLiquidationVolume(ord);
        value = calcCollateral(ord.lowerVol, ord).add(iv)
            .mul(volume.toUint120()).div(ord.written).div(volumeBase);
        
        orders[ord.id].written = uint(orders[ord.id].written).sub(volume).toUint120();
        if (shouldRemove(ord.id)) {
            removeOrder(symbol, ord.id);
        }

        creditProvider.processPayment(ord.owner, token, value);
    }

    function calcLiquidationVolume(OrderData memory ord) private view returns (uint volume) {
        
        uint bal = creditProvider.balanceOf(ord.owner);
        uint collateral = calcCollateral(ord.owner);
        require(collateral > bal, "unfit for liquidation");

        volume = collateral.sub(bal).mul(volumeBase).mul(ord.written).div(
            calcCollateral(uint(ord.upperVol).sub(uint(ord.lowerVol)), ord)
        );

        volume = MoreMath.min(volume, ord.written);
    }

    function shouldRemove(uint id) private view returns (bool) {

        return orders[id].written == 0 && orders[id].holding == 0;
    }
    
    function removeOrder(string memory symbol, uint64 id) private {
        
        address owner = orders[id].owner;
        Arrays.removeItem(tokenIds[symbol], id);
        Arrays.removeItem(book[owner], id);
        delete index[owner][symbol];
        delete orders[id];
    }

    function getOptionSymbol(OrderData memory ord) private view returns (string memory symbol) {
        
        symbol = string(abi.encodePacked(
            UnderlyingFeed(ord.udlFeed).symbol(),
            "-",
            "E",
            ord.option._type == OptionType.CALL ? "C" : "P",
            "-",
            MoreMath.toString(ord.option.strike),
            "-",
            MoreMath.toString(ord.option.maturity)
        ));
    }
    
    function ensureFunds(address owner) private view {
        
        require(
            creditProvider.balanceOf(owner) >= calcCollateral(owner),
            "insufficient collateral"
        );
    }
    
    function calcCollateral(uint vol, OrderData memory ord) private view returns (uint) {
        
        return (vol.mul(ord.written).mul(MoreMath.sqrt(daysToMaturity(ord)))).div(sqrtTimeBase);
    }
    
    function calcIntrinsicValue(OrderData memory ord) private view returns (int value) {
        
        OptionData memory opt = ord.option;
        int udlPrice = getUdlPrice(ord);
        int strike = int(opt.strike);

        if (opt._type == OptionType.CALL) {
            value = MoreMath.max(0, udlPrice.sub(strike));
        } else if (opt._type == OptionType.PUT) {
            value = MoreMath.max(0, strike.sub(udlPrice));
        }
    }
    
    function isValid(OrderData memory ord) private pure returns (bool) {
        
        return ord.id > 0;
    }
    
    function daysToMaturity(OrderData memory ord) private view returns (uint d) {
        
        uint _now = getUdlNow(ord);
        if (ord.option.maturity > _now) {
            d = (timeBase.mul(uint(ord.option.maturity).sub(uint(_now)))).div(1 days);
        } else {
            d = 0;
        }
    }

    function getUdlPrice(OrderData memory ord) private view returns (int answer) {

        if (ord.option.maturity > time.getNow()) {
            (,answer) = UnderlyingFeed(ord.udlFeed).getLatestPrice();
        } else {
            (,answer) = UnderlyingFeed(ord.udlFeed).getPrice(ord.option.maturity);
        }
    }

    function getUdlNow(OrderData memory ord) private view returns (uint timestamp) {

        (timestamp,) = UnderlyingFeed(ord.udlFeed).getLatestPrice();
    }
}