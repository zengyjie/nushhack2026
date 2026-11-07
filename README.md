## Inspiration

Security and continuity of operations in the military are crucial. However, most existing solutions for military health units are unable to bridge the gap between online and offline operation, which is crucial in the present day and age due to the risk of cyber and infrastructure attacks that can cause momentary internet disruption.

## What it does

M#SH has 2 main functionalities:

 - Provides a HQ to field hospital management system for coordinated operations
 - Enables intra-tent communication via BLE when internet is disrupted

M#SH is able to track patient reports, data as well as resource inventory. It ensures that any possible conflicting reports can be resolved efficiently by an administrator through the main dashboard.

## How we built it

Frontend:		Flutter​
Bluetooth:		Kotlin BLE API
Offline storage:	SQLite​
Backend:		FastAPI on Python​
HQ Database:	PostgreSQL​
Authentication:	EdDSA (private/public key)​

## Challenges we ran into

 - git branch management
 - balancing time for idea generation and product development

## Accomplishments that we're proud of

We were pleasantly surprised at the speed and robustness of the BLE technology implemented. Data could be transmitted across relatively long distances and updated with little lag.

## What we learned

 - The capabilities of bluetooth communication
 - Flutter UI design
 - How to name and design a logo for an app

## What's next for M#SH

 - More robust inventory system with ML resource prediction when offline
