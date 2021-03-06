/**
 Copyright (C) 2016  Johan Degraeve
 
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/gpl.txt>.
 
 */
package services
{
	import com.distriqt.extension.bluetoothle.AuthorisationStatus;
	import com.distriqt.extension.bluetoothle.BluetoothLE;
	import com.distriqt.extension.bluetoothle.BluetoothLEState;
	import com.distriqt.extension.bluetoothle.events.BluetoothLEEvent;
	import com.distriqt.extension.bluetoothle.events.CharacteristicEvent;
	import com.distriqt.extension.bluetoothle.events.PeripheralEvent;
	import com.distriqt.extension.bluetoothle.objects.Characteristic;
	import com.distriqt.extension.bluetoothle.objects.Peripheral;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.TimerEvent;
	import flash.utils.ByteArray;
	import flash.utils.Endian;
	import flash.utils.Timer;
	
	import Utilities.HM10Attributes;
	import Utilities.Trace;
	
	import databaseclasses.BlueToothDevice;
	
	import distriqtkey.DistriqtKey;
	
	import events.BlueToothServiceEvent;
	
	import model.ModelLocator;
	import model.TransmitterDataXBridgeBeaconPacket;
	import model.TransmitterDataXBridgeDataPacket;
	import model.TransmitterDataXdripDataPacket;
	
	/**
	 * all functionality related to bluetooth connectivity<br>
	 * init function must be called once immediately at start of the application<br>
	 * <br>
	 * to get info about connectivity status, new transmitter data ... check BluetoothServiceEvent  create listeners for the events<br>
	 * BluetoothService itself is not doing anything with the data received from the bluetoothdevice, also not checking the transmit id, it just passes the information via 
	 * dispatching<br>
	 * <br>
	 * There is also a method to update the transmitter id, however the bluetoothservice is not handling the response, it just tries to send the message to the device, no guarantee that this will succeed.
	 */
	public class BluetoothService extends EventDispatcher
	{
		
		private static var _instance:BluetoothService = new BluetoothService();
		
		[ResourceBundle("bluetoothservice")]
		public static function get instance():BluetoothService
		{
			return _instance;
		}
		
		private static var _activeBluetoothPeripheral:Peripheral;
		
		private static var initialStart:Boolean = true;
		
		private static var scanTimer:Timer;
		private static const MAX_SCAN_TIME_IN_SECONDS:int = 15;
		private static var discoverServiceOrCharacteristicTimer:Timer;
		private static const DISCOVER_SERVICES_OR_CHARACTERISTICS_RETRY_TIME_IN_SECONDS:int = 1;
		private static const MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS:int = 5;
		private static var amountOfDiscoverServicesOrCharacteristicsAttempt:int = 0;
		
		private static const reconnectAttemptPeriodInSeconds:int = 25;
		//private static var reconnectTimer:Timer;
		//private static var reconnectAttemptTimeStamp:Number = 0;
		//private static var reScanIfFailed:Boolean = false;
		
		//private static var connectionAttemptCheckTimer:Timer;
		
		private static const lengthOfDataPacket:int = 17;
		private static const srcNameTable:Array = [ '0', '1', '2', '3', '4', '5', '6', '7',
			'8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
			'G', 'H', 'J', 'K', 'L', 'M', 'N', 'P',
			'Q', 'R', 'S', 'T', 'U', 'W', 'X', 'Y' ];
		
		private static var timeStampOfLastDataPacketReceived:Number = 0;
		private static const uuids_HM_10_Service:Vector.<String> = new <String>[HM10Attributes.HM_10_SERVICE];
		private static const uuids_HM_RX_TX:Vector.<String> = new <String>[HM10Attributes.HM_RX_TX];
		private static const debugMode:Boolean = true;

		private static function set activeBluetoothPeripheral(value:Peripheral):void
		{
			if (value == _activeBluetoothPeripheral)
				return;
			
			_activeBluetoothPeripheral = value;
			
			if (_activeBluetoothPeripheral != null) {
				_activeBluetoothPeripheral.addEventListener(PeripheralEvent.DISCOVER_SERVICES, peripheral_discoverServicesHandler );
				_activeBluetoothPeripheral.addEventListener(PeripheralEvent.DISCOVER_CHARACTERISTICS, peripheral_discoverCharacteristicsHandler );
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.UPDATE, peripheral_characteristic_updatedHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.UPDATE_ERROR, peripheral_characteristic_errorHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.SUBSCRIBE, peripheral_characteristic_subscribeHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.SUBSCRIBE_ERROR, peripheral_characteristic_subscribeErrorHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.UNSUBSCRIBE, peripheral_characteristic_unsubscribeHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.WRITE_SUCCESS, peripheral_characteristic_writeHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.WRITE_ERROR, peripheral_characteristic_writeErrorHandler);
			}
		}
		
		private static function get activeBluetoothPeripheral():Peripheral {
			return _activeBluetoothPeripheral;
		}
		
		private static var _characteristic:Characteristic;
		
		private static function get characteristic():Characteristic
		{
			return _characteristic;
		}
		
		private static function set characteristic(value:Characteristic):void
		{
			_characteristic = value;
		}
		
		public function BluetoothService()
		{
			if (_instance != null) {
				throw new Error("BluetoothService class constructor can not be used");	
			}
		}
		
		/**
		 * start all bluetooth related activity : scanning, connecting, start listening ...<br>
		 * Also intializes BlueToothDevice with values retrieved from Database. 
		 */
		public static function init():void {
			if (!initialStart)
				return;
			else
				initialStart = false;
			
			BluetoothLE.init(DistriqtKey.distriqtKey);
			if (BluetoothLE.isSupported) {
				myTrace("passing bluetoothservice.issupported");
				myTrace("authorisation status = " + BluetoothLE.service.authorisationStatus());
				switch (BluetoothLE.service.authorisationStatus()) {
					case AuthorisationStatus.SHOULD_EXPLAIN:
						BluetoothLE.service.requestAuthorisation();
						break;
					case AuthorisationStatus.DENIED:
					case AuthorisationStatus.RESTRICTED:
					case AuthorisationStatus.UNKNOWN:
						break;
			
					case AuthorisationStatus.NOT_DETERMINED:
					case AuthorisationStatus.AUTHORISED:				
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.DISCOVERED, central_peripheralDiscoveredHandler);
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.CONNECT, central_peripheralConnectHandler );
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.CONNECT_FAIL, central_peripheralDisconnectHandler );
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.DISCONNECT, central_peripheralDisconnectHandler );
						BluetoothLE.service.addEventListener(BluetoothLEEvent.STATE_CHANGED, bluetoothStateChangedHandler);
						
						var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INITIATED);
						_instance.dispatchEvent(blueToothServiceEvent);
						
						switch (BluetoothLE.service.centralManager.state)
						{
							case BluetoothLEState.STATE_ON:	
								// We can use the Bluetooth LE functions
								bluetoothStatusIsOn();
								dispatchInformation('bluetooth_is_switched_on');
								break;
							case BluetoothLEState.STATE_OFF:
								dispatchInformation('bluetooth_is_switched_off');
								break;
							case BluetoothLEState.STATE_RESETTING:	
								break;
							case BluetoothLEState.STATE_UNAUTHORISED:
								break;
							case BluetoothLEState.STATE_UNSUPPORTED:
								break;
							case BluetoothLEState.STATE_UNKNOWN:
								break;
						}
				}
				
			} else {
				myTrace("Unfortunately your android version does not support Bluetooth Low Energy");
				dispatchInformation('bluetooth_not_supported');
			}
		}
		
		private static function treatNewBlueToothStatus(newStatus:String):void {
			switch (BluetoothLE.service.centralManager.state)
			{
				case BluetoothLEState.STATE_ON:	
					dispatchInformation('bluetooth_is_switched_on');
					// We can use the Bluetooth LE functions
					bluetoothStatusIsOn();
					break;
				case BluetoothLEState.STATE_OFF:
					dispatchInformation('bluetooth_is_switched_off');
					break;//does the device automatically change to connected ? 
				case BluetoothLEState.STATE_RESETTING:	
					break;
				case BluetoothLEState.STATE_UNAUTHORISED:	
					break;
				case BluetoothLEState.STATE_UNSUPPORTED:	
					break;
				case BluetoothLEState.STATE_UNKNOWN:
					break;
			}
		}
		
		private static function bluetoothStateChangedHandler(event:BluetoothLEEvent):void
		{
			treatNewBlueToothStatus(BluetoothLE.service.centralManager.state);					
		}
		
		/** as soon as bluetooth status is on<br>
		 * &nbsp&nbsp (this may happen the first time that this class is instantiated, means it's instantiated while bluetooth is on<br>
		 * &nbsp&nbsp or bluetooth was off before, while the app was running already, and it changed to on) <br>
		 * 
		 * If a bluetooth peripheral already stored in database, check status and if not connected or connecting, then try to connect<br>
		 * If no active bluetooth peripheral known, then do nothing<br>
		 */
		private static function bluetoothStatusIsOn():void {
			if (activeBluetoothPeripheral != null) {
				BluetoothLE.service.centralManager.connect(activeBluetoothPeripheral);
				dispatchInformation('trying_to_connect_to_known_device');
			} else {
				if (BlueToothDevice.known()) {
					//we know a device from previous connection should we should try to connect
					startScanning();
				}
			}
		}
		
		public static function startScanning():void {
			if (!BluetoothLE.service.centralManager.isScanning) {
				scanTimer = new Timer(MAX_SCAN_TIME_IN_SECONDS * 1000, 1);
				scanTimer.addEventListener(TimerEvent.TIMER, stopScanning);
				scanTimer.start();
				if (!BluetoothLE.service.centralManager.scanForPeripherals(uuids_HM_10_Service))
				{
					dispatchInformation('failed_to_start_scanning_for_peripherals');
					return;
				} else {
					dispatchInformation('started_scanning_for_peripherals');
				}
			}			
		}
		
		private static function stopScanning(event:Event):void {
			if (BluetoothLE.service.centralManager.isScanning) {
				BluetoothLE.service.centralManager.stopScan();
				dispatchInformation('stopped_scanning');	
				_instance.dispatchEvent(new BlueToothServiceEvent(BlueToothServiceEvent.STOPPED_SCANNING));
			}
			/*if (reScanIfFailed) {
				if ((BluetoothLE.service.centralManager.state == BluetoothLEState.STATE_ON)) {
					bluetoothStatusIsOn();
				}
			}*/
				
		}
		
		private static function central_peripheralDiscoveredHandler(event:PeripheralEvent):void {
			myTrace("BluetoothService.as passing in central_peripheralDiscoveredHandler");
			
			// event.peripheral will contain a Peripheral object with information about the Peripheral
			if ((event.peripheral.name as String).toUpperCase().indexOf("DRIP") > -1 || (event.peripheral.name as String).toUpperCase().indexOf("BRIDGE") > -1 || (event.peripheral.name as String).toUpperCase().indexOf("LIMITTER") > -1) {
				var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INFORMATION_EVENT);
				blueToothServiceEvent.data = new Object();
				blueToothServiceEvent.data.information = 
					ModelLocator.resourceManagerInstance.getString('bluetoothservice','found_peripheral_with_name') +
					" = " + event.peripheral.name;
				_instance.dispatchEvent(blueToothServiceEvent);
				
				if (BlueToothDevice.address != "") {
					if (BlueToothDevice.address != event.peripheral.uuid) {
						//a bluetooth device address is already stored, but it's not the one for which peripheraldiscoveredhandler is called
						//so we ignore it
						dispatchInformation('stored_uuid_does_not_match');
						return;
					}
				} else {
					//we store also this device, as of now, all future connect attempts will be only to this one, until the user choses "forget device"
					BlueToothDevice.address = event.peripheral.uuid;
					BlueToothDevice.name = event.peripheral.name;
					dispatchInformation('device_id_stored');
				}
				
				//we want to connect to this device, so stop scanning
				BluetoothLE.service.centralManager.stopScan();
				//reScanIfFailed = false;
				
				BluetoothLE.service.centralManager.connect(event.peripheral);
				dispatchInformation('stop_scanning_and_try_to_connect');
			}
		}
		
		private static function central_peripheralConnectHandler(event:PeripheralEvent):void {
			dispatchInformation('connected_to_peripheral');
			
			if (activeBluetoothPeripheral == null) {
				myTrace("Bluetoothservice.as activeBluetoothPeripheral == null, assigning activeBluetoothPeripheral");
				activeBluetoothPeripheral = event.peripheral;
			} else {
			}
			discoverServices();
		}
		
		private static function discoverServices(event:Event = null):void {
			myTrace("bluetoothservice.as in discoverServices");
			if (activeBluetoothPeripheral == null)//rare case, user might have done forget xdrip while waiting for rettempt
				return;
			myTrace("bluetoothservice.as still in discoverServices");
			
			
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			
			if (amountOfDiscoverServicesOrCharacteristicsAttempt < MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS) {
				amountOfDiscoverServicesOrCharacteristicsAttempt++;
				var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INFORMATION_EVENT);
				blueToothServiceEvent.data = new Object();
				blueToothServiceEvent.data.information = ModelLocator.resourceManagerInstance.getString('bluetoothservice','launching_discoverservices_attempt_amount') + " " + amountOfDiscoverServicesOrCharacteristicsAttempt;
				_instance.dispatchEvent(blueToothServiceEvent);
				myTrace("BluetoothService.as launching_discoverservices_attempt_amount " + amountOfDiscoverServicesOrCharacteristicsAttempt);
				
				activeBluetoothPeripheral.discoverServices(uuids_HM_10_Service);
				discoverServiceOrCharacteristicTimer = new Timer(DISCOVER_SERVICES_OR_CHARACTERISTICS_RETRY_TIME_IN_SECONDS * 1000, 1);
				discoverServiceOrCharacteristicTimer.addEventListener(TimerEvent.TIMER, discoverServices);
				discoverServiceOrCharacteristicTimer.start();
			} else {
				dispatchInformation("max_amount_of_discover_services_attempt_reached");
				amountOfDiscoverServicesOrCharacteristicsAttempt = 0;
				myTrace("BluetoothService.as max_amount_of_discover_services_attempt_reached");
				
				//i just happens that retrying doesn't help anymore
				//so disconnecting and rescanning seems the only solution ?

				//disconnect will cause central_peripheralDisconnectHandler to be called (although not sure because setting activeBluetoothPeripheral to null, i would expect that removes also the eventlisteners
				//central_peripheralDisconnectHandler will see that activeBluetoothPeripheral == null and so 
				var temp:Peripheral = activeBluetoothPeripheral;
				activeBluetoothPeripheral = null;
				BluetoothLE.service.centralManager.disconnect(temp);
				
				var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INFORMATION_EVENT);
				blueToothServiceEvent.data = new Object();
				blueToothServiceEvent.data.information = ModelLocator.resourceManagerInstance.getString('bluetoothservice','will_re_scan_for_device');
				_instance.dispatchEvent(blueToothServiceEvent);
				myTrace("BluetoothService.as will_re_scan_for_device");
				
				bluetoothStatusIsOn();
			}
		}
		
		private static function central_peripheralDisconnectHandler(event:Event = null):void {
			dispatchInformation('disconnected_from_device');
			if (activeBluetoothPeripheral != null) {
				// this is a case where disconnect happened for a device that was already connected
				// automatic reconnect is required.
				myTrace("BluetoothService.as disconnected_from_device and activeBluetoothPeripheral != null");
				BluetoothLE.service.centralManager.disconnect(activeBluetoothPeripheral);
			} 
			activeBluetoothPeripheral = null;
		}
		
		public static function tryReconnect(event:Event = null):void {
			myTrace("BluetoothService.as tryReconnect");
			if ((BluetoothLE.service.centralManager.state == BluetoothLEState.STATE_ON)) {
				bluetoothStatusIsOn();
			} else {
			}
		}
		
		private static function peripheral_discoverServicesHandler(event:PeripheralEvent):void {
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			
			dispatchInformation("services_discovered");
			amountOfDiscoverServicesOrCharacteristicsAttempt = 0;
			
			if (event.peripheral.services.length > 0)
			{
				discoverCharacteristics();
			}
		}
		
		private static function discoverCharacteristics(event:Event = null):void {
			if (activeBluetoothPeripheral == null)//rare case, user might have done forget xdrip while waiting to reattempt
				return;
			
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			
			if (amountOfDiscoverServicesOrCharacteristicsAttempt < MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS) {
				amountOfDiscoverServicesOrCharacteristicsAttempt++;
				var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INFORMATION_EVENT);
				blueToothServiceEvent.data = new Object();
				blueToothServiceEvent.data.information = ModelLocator.resourceManagerInstance.getString('bluetoothservice','launching_discovercharacteristics_attempt_amount') + " " + amountOfDiscoverServicesOrCharacteristicsAttempt;
				_instance.dispatchEvent(blueToothServiceEvent);
				
				//find the index of the service that has uuid = the one used by xdrip/xbridge
				var index:int;
				for each (var o:Object in activeBluetoothPeripheral.services) {
					if (HM10Attributes.HM_10_SERVICE.indexOf(o.uuid as String) > -1) {
						break;
					}
					index++;
				}
				if (activeBluetoothPeripheral.services.length > 0) {
					activeBluetoothPeripheral.discoverCharacteristics(activeBluetoothPeripheral.services[index], uuids_HM_RX_TX);
					discoverServiceOrCharacteristicTimer = new Timer(DISCOVER_SERVICES_OR_CHARACTERISTICS_RETRY_TIME_IN_SECONDS * 1000, 1);
					discoverServiceOrCharacteristicTimer.addEventListener(TimerEvent.TIMER, discoverCharacteristics);
					discoverServiceOrCharacteristicTimer.start();
				}
			} else {
				dispatchInformation("max_amount_of_discover_characteristics_attempt_reached");
				tryReconnect();
			}
		}
		
		private static function peripheral_discoverCharacteristicsHandler(event:PeripheralEvent):void {
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			dispatchInformation("characteristics_discovered");
			amountOfDiscoverServicesOrCharacteristicsAttempt = 0;
			
			//find the index of the service that has uuid = the one used by xdrip/xbridge
			var servicesIndex:int;
			var o:Object;
			for each (o in activeBluetoothPeripheral.services) {
				if (HM10Attributes.HM_10_SERVICE.indexOf(o.uuid as String) > -1) {
					break;
				}
				servicesIndex++;
			}
			
			var characteristicsIndex:int;
			for each (o in activeBluetoothPeripheral.services[servicesIndex].characteristics) {
				if (HM10Attributes.HM_RX_TX.indexOf(o.uuid as String) > -1) {
					break;
				}
				characteristicsIndex++;
			}
			
			characteristic = event.peripheral.services[servicesIndex].characteristics[characteristicsIndex];
			if (!activeBluetoothPeripheral.subscribeToCharacteristic(characteristic))
			{
				dispatchInformation("subscribe_to_characteristic_failed_due_to_invalid_state");
			}
		}
		
		/**
		 * simply acknowledges receipt of a message, needed for xbridge so that it goes to sleep<br>
		 * Can also be the transmitter id. 
		 */
		public static function ackCharacteristicUpdate(value:ByteArray):void {
			if (!activeBluetoothPeripheral.writeValueForCharacteristic(characteristic, value)) {
				dispatchInformation("write_value_for_characteristic_failed_due_to_invalid_state");
			}
		}
		
		private static function peripheral_characteristic_updatedHandler(event:CharacteristicEvent):void {
			/*for (var i:int = 0;i < event.characteristic.value.length;i++) {
				myTrace("BluetoothService.as bytearray element " + i + " = " + (new Number(event.characteristic.value[i])).toString(16));
			}*/
			
			
			//now start reading the values
			var value:ByteArray = event.characteristic.value;
			var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INFORMATION_EVENT);
			blueToothServiceEvent.data = new Object();
			var packetlength:int = value.readUnsignedByte();
			if (packetlength == 0) {
				blueToothServiceEvent.data.information = 
					ModelLocator.resourceManagerInstance.getString('bluetoothservice','data_packet_received_from_transmitter_with_length_0');
				_instance.dispatchEvent(blueToothServiceEvent);
				//ignoring this packet because length is 0
			} else {
				value.position = 0;
				value.endian = Endian.LITTLE_ENDIAN;
				var packetLength:int = value.readUnsignedByte();
				//position = 1
				var packetType:int = value.readUnsignedByte();//0 = data packet, 1 =  TXID packet, 0xF1 (241 if read as unsigned int) = Beacon packet
				var rawData:Number = Number.NaN;
				if (packetType == 0) {
					rawData = value.readInt();
				}

				blueToothServiceEvent.data.information = 
					ModelLocator.resourceManagerInstance.getString('bluetoothservice','data_packet_received_from_transmitter_with') +
					" byte 0 = " + packetlength + " and byte 1 = " + packetType + " and rawData = " + rawData;
				_instance.dispatchEvent(blueToothServiceEvent);
				
				value.position = 0;
				processTransmitterData(value);
			}
		}
		
		private static function peripheral_characteristic_writeHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_writeHandler");
		}
		
		private static function peripheral_characteristic_writeErrorHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_writeErrorHandler");
			dispatchInformation("failed_to_write_value_for_characteristic_to_device");
		}
		
		private static function peripheral_characteristic_errorHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_errorHandler" );
			dispatchInformation("characteristic_update_error_received");
		}
		
		private static function peripheral_characteristic_subscribeHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_subscribeHandler: " + event.characteristic.uuid);
			dispatchInformation("successfully_subscribed_to_characteristics");
			_instance.dispatchEvent(new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_DEVICE_CONNECTION_COMPLETED));
			NotificationService.updateAllNotifications(null);
		}
		
		private static function peripheral_characteristic_subscribeErrorHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_subscribeErrorHandler: " + event.characteristic.uuid);
			dispatchInformation("subscribe_to_characteristics_failed");
		}
		
		private static function peripheral_characteristic_unsubscribeHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_unsubscribeHandler: " + event.characteristic.uuid);	
		}
		
		private static function dispatchInformation(informationResourceName:String):void {
			var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INFORMATION_EVENT);
			blueToothServiceEvent.data = new Object();
			blueToothServiceEvent.data.information = ModelLocator.resourceManagerInstance.getString("bluetoothservice",informationResourceName);
			_instance.dispatchEvent(blueToothServiceEvent);
			myTrace(ModelLocator.resourceManagerInstance.getString("bluetoothservice",informationResourceName));
		}
		
		
		/**
		 * Disconnects the active bluetooth peripheral if any and sets it to null(otherwise returns without doing anything)<br>
		 */
		public static function forgetBlueToothDevice():void {
			if (activeBluetoothPeripheral == null)
				return;
			
			BluetoothLE.service.centralManager.disconnect(activeBluetoothPeripheral);
			activeBluetoothPeripheral = null;
			
			var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INFORMATION_EVENT);
			blueToothServiceEvent.data = new Object();
			blueToothServiceEvent.data.information = ModelLocator.resourceManagerInstance.getString('bluetoothservice','bluetoothdeviceforgotten');
			_instance.dispatchEvent(blueToothServiceEvent);
		}
		
		/**
		 * encode transmitter id as explained in xBridge2.pdf 
		 */
		public static function encodeTxID(TxID:String):Number {
			var returnValue:Number = 0;
			var tmpSrc:String = TxID.toUpperCase();
			returnValue |= getSrcValue(tmpSrc.charAt(0)) << 20;
			returnValue |= getSrcValue(tmpSrc.charAt(1)) << 15;
			returnValue |= getSrcValue(tmpSrc.charAt(2)) << 10;
			returnValue |= getSrcValue(tmpSrc.charAt(3)) << 5;
			returnValue |= getSrcValue(tmpSrc.charAt(4));
			return returnValue;
		}
		
		private static function decodeTxID(TxID:Number):String {
			var returnValue:String = "";
			returnValue += srcNameTable[(TxID >> 20) & 0x1F];
			returnValue += srcNameTable[(TxID >> 15) & 0x1F];
			returnValue += srcNameTable[(TxID >> 10) & 0x1F];
			returnValue += srcNameTable[(TxID >> 5) & 0x1F];
			returnValue += srcNameTable[(TxID >> 0) & 0x1F];
			return returnValue;
		}
		
		private static function getSrcValue(ch:String):int {
			var i:int = 0;
			for (i = 0; i < srcNameTable.length; i++) {
				if (srcNameTable[i] == ch) break;
			}
			return i;
		}
		
		private static function processTransmitterData(buffer:ByteArray):void {
			buffer.endian = Endian.LITTLE_ENDIAN;
			var packetLength:int = buffer.readUnsignedByte();
			//position = 1
			var packetType:int = buffer.readUnsignedByte();//0 = data packet, 1 =  TXID packet, 0xF1 (241 if read as unsigned int) = Beacon packet
			var txID:Number;
			var xBridgeProtocolLevel:Number
			switch (packetType) {
				case 0:
					//data packet
					var rawData:Number = buffer.readInt();
					var filteredData:Number = buffer.readInt();
					var transmitterBatteryVoltage:Number = buffer.readUnsignedByte();
					
					//following only if the name of the device contains "bridge", if it' doesnt contain bridge, then it's an xdrip (old) and doesn't have those bytes' +
					//or if packetlenth == 17, why ? because it could be a drip with xbridge software but still with a name xdrip, because it was originally an xdrip that was later on overwritten by the xbridge software, in that case the name will still by xdrip and not xbridge
					if (BlueToothDevice.isXBridge() || packetLength == 17) {
						var bridgeBatteryPercentage:Number = buffer.readUnsignedByte();
						txID = buffer.readInt();
						xBridgeProtocolLevel = buffer.readUnsignedByte();
						
						var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.TRANSMITTER_DATA);
						blueToothServiceEvent.data = new TransmitterDataXBridgeDataPacket(rawData, filteredData, transmitterBatteryVoltage, bridgeBatteryPercentage, decodeTxID(txID));
						_instance.dispatchEvent(blueToothServiceEvent);
					} else {
						var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.TRANSMITTER_DATA);
						blueToothServiceEvent.data = new TransmitterDataXdripDataPacket(rawData, filteredData, transmitterBatteryVoltage);
						_instance.dispatchEvent(blueToothServiceEvent);
					}
					
					timeStampOfLastDataPacketReceived = (new Date()).valueOf();
					break;
				case 1://will actually never happen, this is a packet type for the other direction , ie from App to xbridge
					//TXID packet
					txID = buffer.readInt();
					break;
				case 241:
					//Beacon packet
					txID = buffer.readInt();
					
					var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.TRANSMITTER_DATA);
					blueToothServiceEvent.data = new TransmitterDataXBridgeBeaconPacket(decodeTxID(txID));
					_instance.dispatchEvent(blueToothServiceEvent);
					
					xBridgeProtocolLevel = buffer.readUnsignedByte();//not needed for the moment
					
					//TODO do this somewhere else
					
					/*var value:ByteArray = new ByteArray();
					value.endian = Endian.LITTLE_ENDIAN;
					value.writeByte(0x06);
					value.writeByte(0x01);
					value.writeInt(encodeTxID("6DJK1"));
					if (!activeBluetoothPeripheral.writeValueForCharacteristic(characteristic, value)) {
					dispatchInformation("write_value_for_characteristic_failed_due_to_invalid_state");
					}*/
					break;
			}
		}
		
		private static function myTrace(log:String):void {
			Trace.myTrace("BluetoothService.as", log);
		}
		
		/**
		 * returns true if activeBluetoothPeripheral != null
		 */
		public static function bluetoothPeripheralActive():Boolean {
			return activeBluetoothPeripheral != null;
		}
	}
	
}