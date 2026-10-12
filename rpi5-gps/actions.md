1. Створити образ Pi OS з допомогою Raspberry PI Imager
1. Підключити модуль
1. Підключитися через ssh
1. Вмикнути UART
	```
	sudo raspi-config nonint do_serial_cons 1   # 1 = disable serial login console
	sudo raspi-config nonint do_serial_hw 0     # 0 = enable serial port hardware
	sudo reboot
	```
1. Перевірити роботу модуля
    ```
	cat /dev/ttyAMA0 # виводить NMEA поток даних
	```
1. Скопіювати скрипт на распбері (powershell)
	```
	scp .\gps_logger.py volodymyr@rpi5.local:~/
	```
1. Встановити скрипт
	```
	python3 -c "import serial; print(serial.__version__)"   # перевірка існування python3-serial
	sudo mkdir -p /opt/gps-logger
	sudo mv ~/gps_logger.py /opt/gps-logger/
	sudo chmod 755 /opt/gps-logger/gps_logger.py
	```
1. Потестувати скрипт вручну
	```
	/opt/gps-logger/gps_logger.py ~/gps/track.csv
	```
1. Встановити скрипт як сервіс і запускати при запуску системи
	```
	sudo tee /etc/systemd/system/gps-logger.service > /dev/null << 'EOF'
	[Unit]
	Description=NEO-6M GPS CSV logger
	After=multi-user.target

	[Service]
	Type=simple
	User=volodymyr
	Group=dialout
	ExecStart=/usr/bin/python3 /opt/gps-logger/gps_logger.py /home/volodymyr/gps/track.csv
	Restart=always
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
	EOF

	sudo systemctl daemon-reload
	sudo systemctl enable --now gps-logger
	sudo reboot
	# reconnect and make sure service runs
	systemctl status gps-logger
	tail -f ~/gps/track.log
	tail -f ~/gps/track.csv
	```