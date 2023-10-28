// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import 'forge-std/Script.sol';
import '../src/KintoID.sol';
import '../src/interfaces/IKintoID.sol';
import '../src/sample/Counter.sol';
import '../src/ETHPriceIsRight.sol';
import '../src/interfaces/IKintoWallet.sol';
import '../src/wallet/KintoWalletFactory.sol';
import '../src/paymasters/SponsorPaymaster.sol';
import { Create2Helper } from '../test/helpers/Create2Helper.sol';
import { UUPSProxy } from '../test/helpers/UUPSProxy.sol';
import { AASetup } from '../test/helpers/AASetup.sol';
import { KYCSignature } from '../test/helpers/KYCSignature.sol';
import { UserOp } from '../test/helpers/UserOp.sol';
import '@aa/core/EntryPoint.sol';
import '@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol';
import { SignatureChecker } from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import 'forge-std/console.sol';

contract KintoInitialDeployScript is Create2Helper,Script {
    using ECDSAUpgradeable for bytes32;
    using SignatureChecker for address;

    KintoWalletFactory _walletFactoryI;
    KintoWalletFactory _walletFactory;
    EntryPoint _entryPoint;
    SponsorPaymaster _sponsorPaymasterImpl;
    SponsorPaymaster _sponsorPaymaster;
    KintoID _implementation;
    KintoID _kintoIDv1;
    UUPSProxy _proxy;
    IKintoWallet _walletImpl;
    IKintoWallet _kintoWalletv1;
    UpgradeableBeacon _beacon;

    function setUp() public {}

    // solhint-disable code-complexity
    function run() public {
        uint256 deployerPrivateKey = vm.envUint('PRIVATE_KEY');
        address deployerPublicKey = vm.envAddress('PUBLIC_KEY');

        vm.startBroadcast(deployerPrivateKey);
        // Kinto ID
        address kintoIDImplAddr = computeAddress(0,
            abi.encodePacked(type(KintoID).creationCode));
        if (isContract(kintoIDImplAddr)) {
            _implementation = KintoID(payable(kintoIDImplAddr));
            console.log('Already deployed Kinto ID implementation at', address(kintoIDImplAddr));
        } else {
            // Deploy Kinto ID implementation
            _implementation = new KintoID{ salt: 0 }();
            console.log('Kinto ID implementation deployed at', address(_implementation));
        }
        address kintoProxyAddr = computeAddress(
            0, abi.encodePacked(type(UUPSProxy).creationCode,
            abi.encode(address(_implementation), '')));
        if (isContract(kintoProxyAddr)) {
            _proxy = UUPSProxy(payable(kintoProxyAddr));
            console.log('Already deployed Kinto ID proxy at', address(kintoProxyAddr));
            _kintoIDv1 = KintoID(address(_proxy));
        } else {
            // deploy proxy contract and point it to implementation
            _proxy = new UUPSProxy{salt: 0}(address(_implementation), '');
            // wrap in ABI to support easier calls
            _kintoIDv1 = KintoID(address(_proxy));
            console.log('Kinto ID proxy deployed at ', address(_kintoIDv1));
            // Initialize proxy
            _kintoIDv1.initialize();
        }
        _kintoIDv1 = KintoID(address(_proxy));

        // Entry Point
        address entryPointAddr = computeAddress(0, abi.encodePacked(type(EntryPoint).creationCode));
        // Check Entry Point
        if (isContract(entryPointAddr)) {
            _entryPoint = EntryPoint(payable(entryPointAddr));
            console.log('Entry Point already deployed at', address(_entryPoint));
        } else {
            // Deploy Entry point
            _entryPoint = new EntryPoint{salt: 0}();
            console.log('Entry point deployed at', address(_entryPoint));
        }

        // Wallet Implementation for the beacon
        address walletImplementationAddr = computeAddress(0, abi.encodePacked(type(KintoWallet).creationCode,
            abi.encode(address(_entryPoint), address(_kintoIDv1))));
        if (isContract(walletImplementationAddr)) {
            _walletImpl = KintoWallet(payable(walletImplementationAddr));
            console.log('Wallet Implementation already deployed at', address(walletImplementationAddr));
        } else {
            // Deploy Wallet Implementation
            _walletImpl = new KintoWallet{salt: 0}(_entryPoint, _kintoIDv1);
            console.log('Wallet Implementation deployed at', address(_entryPoint));
        }

        // Deploys New Upgradeable beacon
        _beacon = new UpgradeableBeacon(address(_walletImpl));

        // Wallet Factory impl
        address walletfImplAddr = computeAddress(0,
            abi.encodePacked(type(KintoWalletFactory).creationCode, abi.encode(address(_beacon))));
        if (isContract(walletfImplAddr)) {
            _walletFactoryI = KintoWalletFactory(payable(walletfImplAddr));
            console.log('Already deployed Kinto Factory implementation at',
                address(walletfImplAddr));
        } else {
            // Deploy Kinto ID implementation
            _walletFactoryI = new KintoWalletFactory{ salt: 0 }(_beacon);
            // Transfer beacon ownership
            _beacon.transferOwnership(address(_walletFactoryI));
            console.log('Kinto Factory implementation deployed at', address(_walletFactoryI));
        }

        // Check Wallet Factory
        address walletFactoryAddr = computeAddress(
            0, abi.encodePacked(type(UUPSProxy).creationCode,
            abi.encode(address(walletfImplAddr), '')));
        if (isContract(walletFactoryAddr)) {
            _walletFactory = KintoWalletFactory(payable(walletFactoryAddr));
            console.log('Wallet factory proxy already deployed at', address(walletFactoryAddr));
        } else {
            // deploy proxy contract and point it to implementation
            _proxy = new UUPSProxy{salt: 0}(address(walletfImplAddr), '');
            // wrap in ABI to support easier calls
            _walletFactory = KintoWalletFactory(address(_proxy));
            console.log('Wallet Factory proxy deployed at ', address(_walletFactory));
            // Initialize proxy
            _walletFactory.initialize(_kintoIDv1);
        }

        address walletFactory = EntryPoint(payable(entryPointAddr)).walletFactory();
        if (walletFactory == address(0)) {
            // Set Wallet Factory in entry point
            _entryPoint.setWalletFactory(address(_walletFactory));
            console.log('Wallet factory set in entry point', _entryPoint.walletFactory());

        } else {
            if (walletFactory != walletFactoryAddr) {
                console.log('WARN: Wallet Factory & Entry Point do not match');
            } else {
                console.log('Wallet factory already deployed and set in entry point',
                    walletFactory);
            }
        }

        // Sponsor Paymaster Implementation
        bytes memory creationCodePaymaster = abi.encodePacked(
            type(SponsorPaymaster).creationCode, abi.encode(address(_entryPoint)));
        address sponsorImplAddr = computeAddress(0, creationCodePaymaster);
        // Check Paymaster implementation
        if (isContract(sponsorImplAddr)) {
            console.log('Paymaster implementation already deployed at', address(sponsorImplAddr));
        } else {
            // Deploy paymaster implementation
            _sponsorPaymasterImpl = new SponsorPaymaster{salt: 0}(IEntryPoint(address(_entryPoint)));
            console.log('Sponsor paymaster implementation deployed at', address(_sponsorPaymasterImpl));
            // deploy proxy contract and point it to implementation
            _proxy = new UUPSProxy(address(_sponsorPaymasterImpl), '');
            // wrap in ABI to support easier calls
            _sponsorPaymaster = SponsorPaymaster(address(_proxy));
            console.log('Paymaster proxy deployed at ', address(_sponsorPaymaster));
            // Initialize proxy
            _sponsorPaymaster.initialize(address(deployerPublicKey));
        }

        // address deployerPublicKey = vm.envAddress('PUBLIC_KEY');
        //_kintoWalletv1 = _walletFactory.createAccount(deployerPublicKey, 0);
        // console.log('wallet deployed at', address(_kintoWalletv1));
        vm.stopBroadcast();
    }
}
