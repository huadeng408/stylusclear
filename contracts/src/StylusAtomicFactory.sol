// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInitializableSettlementEngine {
    function initialize(address initialAdmin, bool benchmarkSeedingEnabled) external;
    function admin() external view returns (address);
    function benchmarkSeedingEnabled() external view returns (bool);
}

interface IArbWasm {
    function activateProgram(address program) external payable returns (uint16 version, uint256 dataFee);
}

/// @title StylusAtomicFactory
/// @notice Atomically deploys via front-run-proof `CREATE2`, activates Stylus WASM programs via `ArbWasm (0x71)`
///         when deployed bytecode carries the `0xEFF000` Stylus prefix (handling `ProgramUpToDate`), and
///         initializes `admin()` + verifies `benchmarkSeedingEnabled` strictly before refunding excess ETH (CEI).
contract StylusAtomicFactory {
    address public constant ARB_WASM = address(0x0000000000000000000000000000000000000071);
    bytes4 private constant PROGRAM_UP_TO_DATE_SELECTOR = 0x3e52a167;

    error DeploymentFailed();
    error ActivationFailed();
    error InitializationFailed();
    error RefundFailed();

    event EngineAtomicallyDeployed(
        address indexed deployedEngine,
        address indexed initialAdmin,
        bytes32 indexed guardedSalt,
        bool benchmarkSeedingEnabled,
        bool stylusActivated
    );

    receive() external payable {}

    function deriveGuardedSalt(address deployer, address initialAdmin, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, initialAdmin, userSalt));
    }

    function computeEngineAddress(
        bytes32 initCodeHash,
        address deployer,
        address initialAdmin,
        bytes32 userSalt
    ) external view returns (address) {
        bytes32 guardedSalt = deriveGuardedSalt(deployer, initialAdmin, userSalt);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), guardedSalt, initCodeHash)))));
    }

    function deployAndInitialize(
        bytes memory initCode,
        bytes32 userSalt,
        address initialAdmin,
        bool benchmarkSeedingEnabled
    ) external payable returns (address engine) {
        if (initCode.length == 0 || initialAdmin == address(0)) revert DeploymentFailed();
        bytes32 guardedSalt = deriveGuardedSalt(msg.sender, initialAdmin, userSalt);
        assembly {
            engine := create2(0, add(initCode, 0x20), mload(initCode), guardedSalt)
        }
        if (engine == address(0) || engine.code.length == 0) revert DeploymentFailed();

        bool stylusActivated = false;
        uint256 refundAmount = msg.value;
        bytes memory deployed = engine.code;
        if (deployed.length >= 3 && deployed[0] == 0xEF && deployed[1] == 0xF0 && deployed[2] == 0x00) {
            if (ARB_WASM.code.length == 0) revert ActivationFailed();
            try IArbWasm(ARB_WASM).activateProgram{value: msg.value}(engine) returns (uint16, uint256 dataFee) {
                stylusActivated = true;
                refundAmount = msg.value > dataFee ? (msg.value - dataFee) : 0;
            } catch (bytes memory reason) {
                if (reason.length >= 4 && bytes4(reason) == PROGRAM_UP_TO_DATE_SELECTOR) {
                    stylusActivated = true;
                    refundAmount = msg.value;
                } else {
                    revert ActivationFailed();
                }
            }
        }

        // Strict CEI: initialize & verify state BEFORE any external ETH refund to msg.sender
        address curAdmin = IInitializableSettlementEngine(engine).admin();
        if (curAdmin == address(0)) {
            IInitializableSettlementEngine(engine).initialize(initialAdmin, benchmarkSeedingEnabled);
            curAdmin = IInitializableSettlementEngine(engine).admin();
        }
        if (
            curAdmin != initialAdmin
                || IInitializableSettlementEngine(engine).benchmarkSeedingEnabled() != benchmarkSeedingEnabled
        ) {
            revert InitializationFailed();
        }

        emit EngineAtomicallyDeployed(engine, initialAdmin, guardedSalt, benchmarkSeedingEnabled, stylusActivated);

        if (refundAmount > 0) {
            (bool ok, ) = msg.sender.call{value: refundAmount}("");
            if (!ok) revert RefundFailed();
        }
    }
}
