// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library Oracle {
    struct Observation {
        //current time this observation was recorded
        uint32 blockTimeStamp;
        //this is the cumulative of tick and timeElapsed
        int56 tickCumulative;
        //this is timeElapsed/liquidity
        uint160 secondsPerLiquidityCumulativeX128;
        //valid or not valid
        bool initialized;
    }

    function transform(Observation memory last, uint32 blockTimeStamp, int24 tick, uint128 liquidity)
        private
        pure
        returns (Observation memory)
    {
        uint32 timeElapsed = blockTimeStamp - last.blockTimeStamp;
        return Observation({
            blockTimeStamp: blockTimeStamp,
            //here we are doing tickCumulative + (tick x timeElapsed
            tickCumulative: last.tickCumulative + tick * int56(uint56(timeElapsed)),
            //here we are doing timeElapsed/liquidity
            //to avoid divide by zero revert, we make it 1
            secondsPerLiquidityCumulativeX128: (uint160(timeElapsed) << 128) / (liquidity > 0 ? liquidity : 1),
            initialized: true
        });
    }

    //initialize the 0 index of the observation
    function initialize(Observation[65535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({
            blockTimeStamp: time,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    //write to observation
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        //since we will reference this variable multiple times, it make sense to write it
        //out to avoid complexity
        Observation memory lastObservation = self[index];
        //we can only write into a block at a time
        if (blockTimestamp == lastObservation.blockTimeStamp) return (index, cardinality);

        //so here we are saying that if cardinalityNext is greater than cardinality(meaning cardinality can be updated) and we are not almost at the end of cardinality, then it is time to bump cardinality up to cardinalityNext..
        //how can cardinalityNext be different from cardinality?? because someone might have increased it with the increaseCardinalityNext function and cardinality might have not be increased as well.
        //we only match cardinality up to the max when it is absolutely neccessary to do so, that is the observation index we have written to is already close., if not that our cardinality should just remain our cardinality
        //@question why are we leaving this gas for the user that is writing to observation?? why don't we just increase the cardinality when we grew the cardinalityNext??
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }
        //here we do modulus of our cardinality with the next index
        //assuming the index is 4 and our cardinality is 6, we have
        //4 % 6 = 4/6 = o remaining 4 which make sense
        //if new index is 6 and cardinality is also 6
        // then 6 % 6 = 6/6 = 0 remainder 0
        //that means our new index we are writing to will be 0, rewriting what was previously there.
        indexUpdated = (index + 1) % cardinalityUpdated;
        self[indexUpdated] = transform(lastObservation, blockTimestamp, tick, liquidity);
    }

    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        require(current > 0);

        //if the new cardinalityNext is lesser than the older one, just return the old one
        if (current <= next) return current;

        /**
         * why do we need to loop here???
         * to optimize gas for every user that interact with the protocol, and because writing to a fresh storage = 20000 gas but writing to an already initialized storage = 2900 gas. Uniswap made sure that anyone that is calling then increaseCardinalityNext function pay for all the gas ahead by initializing the observation storage for whatever amount of cardinality. these observation is invalid because we have not set the validity to true.
         */
        for (uint256 i = current; i < next; i++) {
            self[i].blockTimeStamp = 1;
        }
        return next;
    }

    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {

        //this less than function even account for year 2106 problem overflow on uint32 timestamp.
        if (a <= time && b <= time) return a <= b;

        uint256 aAdjusted = a > time ? a : a + 2e32;
        uint256 bAdjusted = b > time ? b : b + 2e32;

        return aAdjusted <= bAdjusted;
    }

    function binarySearch(Observation[65535] storage self, uint32 time, uint32 target, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory afterOrAt)
    {
        uint256 l = (index + 1) % cardinality;
        uint256 r = l + cardinality - 1;
        uint256 i;

        while (true) {
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            afterOrAt = self[(i + 1) % cardinality];

            bool targetAtOrAfter = lte(time, beforeOrAt.blockTimeStamp, target);

            if (targetAtOrAfter && lte(time, afterOrAt.blockTimeStamp, target)) break;

            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        /**
         * so in this function we are giving a time, that we should find an observation that match that time - but most time since observation aren't updated every second, there might be time where there is no observations - so this function help us to find the closest match.
         */
        beforeOrAt = self[index];

        /**
         * Here we check if the previous beforeOrAt we got is a match with our target, if it is - we can just return and don't need to bother about the afterOrAt
         */
        //we are saying if beforeOrAt <= target
        if (lte(time, beforeOrAt.blockTimeStamp, target)) {
            if (beforeOrAt.blockTimeStamp == target) {
                return (beforeOrAt, atOrAfter);
            } else {
                //but if the beforeOrAt, is actually before out target, we can return it as it is but then transform our actual target into an observation
                //wait, if we can transform any observation - why not just do it from the start?? because we only transform when we have a beforeOrAt reference, when we dont have that we cannot transform.  apart from that it is cheaper just getting the exact match and returning it.
                return (beforeOrAt, transform(beforeOrAt, target, tick, liquidity));
            }
        }

        /**
         * what is the point for this check???
         *
         * we are checking to make sure our target is not older than our oldest observation.
         */
        //first, we get the oldest observation
        beforeOrAt = self[(index + 1) % cardinality]; 
        //Next we check if our observation is initialized, if it is not - it means we are still in the linear route so please just set the observation to the OG observation which is at index 0.
        if (!beforeOrAt.initialized) beforeOrAt = self[0];
        // here is the actual check
        require(lte(time, beforeOrAt.blockTimeStamp, target), "OLD");

        /**
         * wait, why go through the stress of finding the returns with binary search??? because the beforeOrAt might atually not be the closest to our target
         */
        return binarySearch(self, time, target, index, cardinality);
    }

    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) {
        /**
         * this is a shortcut to bypass to return the latest observation by entering secondsAgo as zero, we just return the observtion at index if it is in this block.timestamp, if it is not then form an observation and return it with the current real life parameter since we know them, you dont neccessarily have to add it to storage or the array of observations.
         */

        if (secondsAgo == 0) {
            Observation memory lastObservation;
            if (lastObservation.blockTimeStamp != time) {
                lastObservation = transform(lastObservation, time, tick, liquidity);
            }
            return (lastObservation.tickCumulative, lastObservation.secondsPerLiquidityCumulativeX128);
        }

        
        /**
         * Now if it is a bit of other seconds ago(let's say 12 seconds ago), you can't exactly just form an observation because we don't even know the tick of 12 seconds ago or anything. highest we can do is get an observation that is at 12 seconds ago...what if 12 second ago - observation was not written??? we just look for observation that is the closest to our target.
         */

        //first let us get the target we are looking for since it is not zero
        uint32 target = time - secondsAgo;
        //now let us find the obsevation at or around this target
        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            getSurroundingObservations(self, time, target, tick, index, liquidity, cardinality);

        //now let us check if our target at our beforeOrAt or it is in our atOrAfter
        if (beforeOrAt.blockTimeStamp == target) {
            return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
        }
        if (atOrAfter.blockTimeStamp == target) {
            return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
        }

        //okay that means if we are not in both edges, we should be at somewhere in the middle. to get tickCumulative for that our exact target, we just have to divide all the tickmulative within the edges and divide it by the time - so that we can get the average tickcumulative per seconds and then multiply the result with how much far our second is from the beforeOrAt...let us just get into it

        //first we find how much time is between the edges
        uint56 timeDelta = atOrAfter.blockTimeStamp - beforeOrAt.blockTimeStamp;
        //next we find how much second is our target away from the edge
        uint56 targetDelta = target - beforeOrAt.blockTimeStamp;
        //now we calculate the changet 

        /**
         * for the tick cumulative, it doesn't make sense to divide by 2, because  we might not be exactly at the middle, so we kind of divide the tickCumulative within the entire range by the time - so we can can get like a subunit to work with it - so it becomes rangeTickCumulative/timeElapsed within range = tickCumulative/seconds.
         * 
         * Now since we know the difference of our target from the beginning observation, we can just use it to multiply it.
         * 
         * More like (tickCumulative/seconds) * targetDelta(how many seconds elapsed from our target to the beginning observation).
         * 
         * same stuff for secondsPerLiquidityCumulativeX128.
         */
        return (
            beforeOrAt.tickCumulative
                + (((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(timeDelta)) * int56(targetDelta)),
            beforeOrAt.secondsPerLiquidityCumulativeX128
                + (
                    (
                        (atOrAfter.secondsPerLiquidityCumulativeX128 - beforeOrAt.secondsPerLiquidityCumulativeX128)
                            * targetDelta
                    ) / timeDelta
                )
        );
    }


    //this function is to observe multiple seconds ago.
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        require(cardinality > 0, "I");

        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) =
                observeSingle(self, time, secondsAgos[i], tick, index, liquidity, cardinality);
        }
    }
}
