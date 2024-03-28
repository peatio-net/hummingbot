
# Peatio Exchange Connector

## March 2024

Peatio is an opensource project for a centralised cryptocurrency exchange platform.

Many cryptocurrency exchanges were originally based on the Peatio project.

The Peatio project is mainly developed using Ruby on Rails, and most implementations use a MySQL database. In the past couple of years a React frontend was added. 

Originally Peatio was funded from an early Bitcoin investor in Chana. The Peatio project went stale until Helios Technology/Openware/Yellow took over, then modernised and extended the project for a few years.

The Hummingbot Exchange Connector for Peatio was added to support centralised exchanges based on the open-source project.

This Peatio Connector was largely based on the Altmarkets connector, as the Altmarkets exchange ran on Peatio. Altmarkets appears to have ceased trading recent;y.

The Connector API has been tested with Peatio version 3.1, although it should work with any verstion of Peatio greater than 2.3, unless the API routes have been changed.

The biggest change was to parameterise the base URL to suit different echanges. Eg. this was originally hard-codes as "www.altmarkets.io". Now the base URL must be enterted as a variable in the config.pt file Eg "www.coinharbour.com.au".
The domain name must be added in the config.py file which will also be mentioned on the user interface after connecting to the peatio server. 

