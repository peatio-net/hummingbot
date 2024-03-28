# Peatio Exchange Connector

## March 2024

Peatio is an opensource project for a centralised cryptocurrency exchange platform. Many large cryptocurrency exchanges were originally based on the Peatio project.

"Peatio" is a mythical Chinese dragon.

The Peatio project is mainly developed using Ruby on Rails, and most implementations use a MySQL database.

Originally Peatio was funded from an early Bitcoin investor in China. The Peatio project went stale until Helios Technology/Openware/Yellow took over, then modernised and extended the project for a few years. From 2020 Peatio was Docker-ised, K8s support added, the frontend rewritten in React and Vault used for encrypting sensitive data.

The Hummingbot Exchange Connector for Peatio was added to support centralised exchanges based on the open-source project.

This Peatio Connector was largely based on the Altmarkets connector, as the Altmarkets exchange ran on Peatio. Altmarkets appears to have ceased trading recently.

The Connector API has been tested with Peatio version 3.1, although it should work with any verstion of Peatio greater than 2.3, unless the API routes have been changed.

The biggest change was to parameterise the base URL to suit different echanges. Eg. this was originally hard-codes as "www.altmarkets.io". Now the base URL must be entered as a variable in the "config.py"" file Eg "www.coinharbour.com.au".

The domain name Eg. www.exchange.io must be added in the config.py (exchange_domain) in the peatio folder file. The server URL is displayed when connecting to a Peatio server in Hummingbot console.

Since Helios/Openware/Yellow has discontinued support for the Peatio/Opendax open-source project, a group has formed on Telegram to continue development of the platform. We hope to release version 3.2 during 2024.

Say hello on our Telegram channel [https://t.me/peatio_dao]()

We originally worked on this Hummingbot Connector as part of an Artificial Intelligence project using a Deep Learning model for smart market-making. Contact us if you are interested in this work.

Any feedback, suggestions of test results would be appreciated.

Peter Cooney
Syed Mateen Hussain
Ian Lenhk
