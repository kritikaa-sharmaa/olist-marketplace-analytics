--tables
select top 1 * from orders
select top 1 * from order_items
select top 1 * from customers
select top 1 * from payments
select top 1 * from products
select top 1 * from category_name_translation
select top 1 * from reviews
select top 1 * from geolocation
select top 1 * from sellers

--TASK 1 - BASIC CHECKS
select *, [Null Count]*100.0/[order count][null%] from 
(SELECT order_status, count(order_id)[order count] ,sum(case when order_delivered_customer_date IS NULL then 1 else 0 end)[Null Count]
FROM orders
group by order_status) t
--Delivered → should have customer delivery date  8 violations
--Canceled → normally should not have customer delivery date → 6 suspicious records

select * from orders where order_delivered_customer_date is null and order_status = 'delivered'
--8 delivered orders have missing customer delivery dates. The issue affects only 0.0083% of delivered orders, so it is low-volume but represents a business-rule inconsistency that should not be silently ignored.

select * from orders where order_delivered_customer_date is not null and order_status = 'canceled'
--6 canceled orders have a customer delivery date populated. The records do not provide enough information to determine why.

select order_id, count(*)[duplicate count] from orders group by order_id having count(*) > 1

select * from products where product_category_name is null
--610 products have missing category information. The available physical attributes are insufficient to reliably impute the category, so the values should not be guessed.


--TASK 2 - Marketplace Baseline
select sum(payment_value)[Total Customer Payment Value] from payments
SELECT COUNT(order_id) AS [Total Orders] FROM orders
select count(distinct customer_unique_id)[Total Customers] from customers
select sum(payment_value)/(SELECT COUNT(order_id) FROM orders)[Average Payment per Order] from payments
select count(seller_id)[Total sellers] from sellers
select count(product_id)[Total Products] from products

select year(order_purchase_timestamp)[year], month(order_purchase_timestamp)[month],count(order_id)[Order count] from orders
group by year(order_purchase_timestamp), month(order_purchase_timestamp) order by year , month

select *, [Order count]-[previous order count][Change] from (select *, lag([Order count]) over(partition by year order by month)[previous order count]
from (select year(order_purchase_timestamp)[year], month(order_purchase_timestamp)[month],count(order_id)[Order count] from orders
group by year(order_purchase_timestamp), month(order_purchase_timestamp) )t )m
-- Order volume was higher in the observed 2018 period than in 2017.
-- However, 2018 is incomplete, so the annual totals do not establish
-- full-year growth and should not be directly compared as full-year performance.

select year(order_purchase_timestamp)[year], count(order_id)[orders count] from orders group by year(order_purchase_timestamp)
--Order volume is higher in 2018 than in 2017, suggesting growth at the annual level. However, 2016 and 2018 are incomplete periods, so we cannot compare them as full-year performance.

select order_status, count(order_id)[order count] from orders group by order_status order by [order count] desc

select o.order_status, sum(p.payment_value)[Value] from orders o inner join payments p on o.order_id = p.order_id
group by o.order_status order by Value

--Is the problem concentrated in particular periods?
with cte as (select year(order_purchase_timestamp)[year], month(order_purchase_timestamp)[month],count(order_id)[Problem Orders] from orders
where order_status = 'canceled' or order_status = 'unavailable'
group by year(order_purchase_timestamp), month(order_purchase_timestamp)),
cte2 as (select year(order_purchase_timestamp)[year], month(order_purchase_timestamp)[month],count(order_id)[total Orders] from orders
group by year(order_purchase_timestamp), month(order_purchase_timestamp))
select t.year, t.month, isnull([Problem Orders],0)[problem orders], [total Orders], 
isnull((([Problem Orders]*100.0)/[total Orders]),0)[problem order %]
from cte c right join cte2 t on c.month = t.month and c.year = t.year order by t.year, t.month

--Are those periods financially important too?
with cte as (select year(order_purchase_timestamp)[year], month(order_purchase_timestamp)[month],sum(p.payment_value)[problem Value] from orders o 
inner join payments p on o.order_id = p.order_id
where order_status = 'canceled' or order_status = 'unavailable'
group by year(order_purchase_timestamp), month(order_purchase_timestamp)),
cte2 as (select year(order_purchase_timestamp)[year], month(order_purchase_timestamp)[month],sum(p.payment_value)[Value] from orders o 
inner join payments p on o.order_id = p.order_id
group by year(order_purchase_timestamp), month(order_purchase_timestamp))
select t.year, t.month, isnull([problem Value],0)[problem payment value], [Value], 
isnull((([problem Value]*100.0)/[Value]),0)[problem payment value %]
from cte c right join cte2 t on c.month = t.month and c.year = t.year order by t.year, t.month

--Do the extreme beginning/end months explain a large share of total problem payment value?
WITH total_problem_value AS (
    SELECT
        SUM(p.payment_value) AS [Total Problem Value]
    FROM orders o
    INNER JOIN payments p
        ON o.order_id = p.order_id
    WHERE o.order_status IN ('canceled', 'unavailable')
),
four_month_problem_value AS (
    SELECT
        SUM(p.payment_value) AS [Four Month Problem Value]
    FROM orders o
    INNER JOIN payments p
        ON o.order_id = p.order_id
    WHERE o.order_status IN ('canceled', 'unavailable')
      AND YEAR(o.order_purchase_timestamp) IN (2016, 2018)
      AND MONTH(o.order_purchase_timestamp) IN (9, 10)
)
SELECT
    t.[Total Problem Value],
    f.[Four Month Problem Value],
    f.[Four Month Problem Value] * 100.0
        / t.[Total Problem Value] AS [Four Month Share %]
FROM total_problem_value t
CROSS JOIN four_month_problem_value f;
-- Conclusion:
-- The extreme rates observed in the partial periods at the beginning
-- and end of the dataset account for only a small share of total
-- problem-order payment value (~4.6%), so they do not explain most
-- of the financial exposure.

--Are cancellations/unavailable orders concentrated in particular product categories?
with cte as (select p.product_category_name, COUNT(DISTINCT o.order_id)[order count] from orders o inner join order_items t on o.order_id = t.order_id inner join products p on p.product_id = t.product_id
where o.order_status = 'canceled' or o.order_status = 'unavailable' group by p.product_category_name),
cte1 as (select p.product_category_name, COUNT(DISTINCT t.order_id)[total order count] from  order_items t right join products p on p.product_id = t.product_id
group by p.product_category_name)
select e.product_category_name, e.[total order count], c.[order count] ,(c.[order count]*100.0)/e.[total order count][% of problem order]
from cte c inner join cte1 e on c.product_category_name = e.product_category_name order by [% of problem order] desc, c.[order count] desc
--No category shows a strong enough combination of volume + problem rate to make it a convincing major finding.The tiny categories with 10–30 orders
--can produce 5–12% rates, but that's too little volume to build a business conclusion around. Meanwhile, the large categories have problem rates around or below ~1%.


--Are cancellations/unavailable orders concentrated among sellers?
with cte as (select t.seller_id, count(distinct o.order_id)[problem order count] from orders o inner join order_items t on o.order_id = t.order_id 
where o.order_status = 'canceled' or o.order_status = 'unavailable' group by t.seller_id),
cte1 as (select t.seller_id, count(distinct o.order_id)[total order count] from orders o inner join order_items t on o.order_id = t.order_id 
group by t.seller_id)
select t.seller_id, t.[total order count], c.[problem order count], (c.[problem order count]*100.0)/t.[total order count][% of problem orders]
from cte c inner join cte1 t on c.seller_id = t.seller_id 
order by [% of problem orders] desc
--Seller problem rate is not giving us a strong signal in the current data. The extreme rates are mostly coming from sellers with very small order volumes, while higher-volume sellers generally show low problem rates.


--TASK - 3 - delivery days

select avg(DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)) from orders
where order_delivered_customer_date is not null and order_status = 'delivered'
-- Average purchase-to-customer delivery time was 12 days among delivered orders.
-- However, the average alone may hide unusually long delivery times,
-- so median and percentile analysis is used next.

select order_id, order_purchase_timestamp, order_delivered_customer_date,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered'
order by difference 
-- Delivery time ranged from 0 to 210 days, indicating substantial variation
-- and the possibility of a long upper tail. Median and percentile analysis
-- is therefore required to understand the typical and extreme delivery experience.

with mid as (select order_id, order_purchase_timestamp, order_delivered_customer_date,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
SELECT DISTINCT
    PERCENTILE_CONT(0.5)
    WITHIN GROUP (ORDER BY difference)
    OVER () AS median_delivery_days
FROM mid
--Median purchase-to-customer delivery time was 10 days, compared with
-- an average of 12 days. The higher mean suggests that longer deliveries
-- are pulling the average upward, so percentile analysis is used next
-- to understand the upper tail.

with mid as (select order_id, order_purchase_timestamp, order_delivered_customer_date,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
SELECT DISTINCT
    PERCENTILE_CONT(0.90)
    WITHIN GROUP (ORDER BY difference)
    OVER () AS p_delivery_days
FROM mid
--P75 = 16  P90 = 23   P95 = 29
--75% of delivered orders were completed within 16 days,
-- 90% within 23 days, and 95% within 29 days.
-- This indicates that most orders were delivered within a relatively
-- moderate timeframe, while a smaller group forms a long-delivery tail.

with cte as (select order_id, order_purchase_timestamp, order_delivered_customer_date,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select count(*)  from cte where delivery_difference <= 29
-- 91,741 delivered orders were completed within 29 days.
-- This provides the denominator context for the upper-tail analysis.

with cte as (select order_id, order_purchase_timestamp, order_delivered_customer_date,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select count(*)  from cte where delivery_difference > 29
-- 4,729 delivered orders took more than 29 days.
-- Since 29 days corresponds to the P95 delivery threshold, this group
-- represents the upper tail of the delivery-time distribution rather
-- than an independently defined business failure threshold.

with cte as (select DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select count(*)*100.0/(select count(*) from orders where order_delivered_customer_date is not null and order_status = 'delivered')
from cte where delivery_difference > 29
-- 4.9% of delivered orders took more than 29 days.
-- This is consistent with the P95 threshold of 29 days and is therefore
-- used as supporting context rather than as a standalone business finding.

with cte as (select order_id, DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select sum(p.payment_value)[slow_tail_payment_value], 
(select sum(m.payment_value) from orders s inner join payments m on m.order_id = s.order_id
where s.order_status = 'delivered' and s.order_delivered_customer_date is not null)[total_delivered_payment_value],
sum(p.payment_value)*100.0/(select sum(m.payment_value)[total value] from orders s inner join payments m on m.order_id = s.order_id
where s.order_status = 'delivered' and s.order_delivered_customer_date is not null)[payment_value_share_pct ]
from cte c inner join payments p on p.order_id = c.order_id where delivery_difference > 29
-- Orders taking more than 29 days represented R$937,613.11 of payment value,
-- equivalent to 6.08% of payment value associated with delivered orders.
-- This indicates that the slowest delivery tail carries some financial
-- exposure, although it is not disproportionately larger than its order share.

with cte as (select order_id,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select count(review_id)[review count], AVG(CAST(r.review_score AS DECIMAL(10,2)))[average score] from cte c 
inner join reviews r on c.order_id = r.order_id  where c.delivery_difference > 29
-- Reviews associated with orders taking more than 29 days had an
-- average review score of 2.2, indicating substantially poorer
-- customer experience within this slow-delivery group.

with cte as (select order_id,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select count(review_id)[review count], AVG(CAST(r.review_score AS DECIMAL(10,2)))[average score] from cte c 
inner join reviews r on c.order_id = r.order_id  where c.delivery_difference <= 29
--91721,  --4
-- Orders taking more than 29 days had an average review score of 2.2,
-- compared with 4.2 for orders delivered within 29 days.
-- This indicates a strong association between very long delivery
-- times and poorer customer experience.
-- This analysis shows association, not causation.

with cte as (select order_id,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select r.review_score, count(r.order_id)[review count],100.0 * count(r.order_id) / sum(count(r.order_id)) over () as [percentage]
from cte c inner join reviews r on c.order_id = r.order_id  where c.delivery_difference > 29
group by r.review_score order by [review count] desc
---- Among reviewed orders taking more than 29 days, 62.1% received
-- 1–2 star ratings, while only 27.1% received 4–5 stars.
-- This supports the observed association between very long delivery
-- times and poorer customer experience.

with cte as (select order_id,
DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[delivery_difference] from orders 
where order_delivered_customer_date is not null and order_status = 'delivered')
select r.review_score, count(r.order_id)[review count],100.0 * count(r.order_id) / sum(count(r.order_id)) over () as [percentage]
from cte c inner join reviews r on c.order_id = r.order_id  where c.delivery_difference <= 29
group by r.review_score order by [review count] desc
-- Orders taking more than 29 days had a substantially worse review
-- distribution than orders delivered within 29 days.
-- 62.1% of reviews for >29-day orders were 1–2 stars, compared with
-- only 10.3% for orders delivered within 29 days. Conversely, 81.5%
-- of reviews for ≤29-day orders were 4–5 stars, compared with 27.1%
-- for >29-day orders.
-- This indicates a strong association between very long delivery times
-- and poorer customer experience; it does not establish causation.

with cte as ( select distinct o.order_id, t.seller_id,
DATEDIFF(DAY,o.order_purchase_timestamp,o.order_delivered_customer_date)[delivery_days] from orders o inner join order_items t
on o.order_id = t.order_id
where order_delivered_customer_date is not null and order_status = 'delivered')
select seller_id, count(order_id)[delivered orders], AVG([delivery_days])[avg delivery days]
,sum(case when [delivery_days] > 29 then 1 else 0 end)[orders > 29],
100.0*(sum(case when [delivery_days] > 29 then 1 else 0 end))/count(order_id)[slow delivery %]
from cte  group by seller_id
HAVING COUNT(order_id) >= 50
-- Seller-level slow-delivery rates varied among sellers with at least
-- 50 delivered orders. This analysis is exploratory and does not, by itself,
-- establish whether slow deliveries are concentrated among a small group
-- of sellers. Seller concentration is therefore not treated as a primary finding.

with cte as (select *, DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[actual delivery days],
DATEDIFF(DAY,order_purchase_timestamp, order_estimated_delivery_date)[expected delivery days]
from orders where order_status = 'delivered'and order_delivered_customer_date is not null)
select count(*)[delay count], count(*)*100.0/(select count(*) from orders where order_status = 'delivered'and order_delivered_customer_date is not null)
[%] from cte
where order_delivered_customer_date > order_estimated_delivery_date
--7826	 --8.112366538820

with cte as (select *,DATEDIFF(DAY,order_purchase_timestamp,order_delivered_customer_date)[actual delivery days],
DATEDIFF(DAY,order_purchase_timestamp, order_estimated_delivery_date)[expected delivery days],
DATEDIFF(DAY, order_estimated_delivery_date, order_delivered_customer_date) AS [days late]
from orders where order_status = 'delivered'and order_delivered_customer_date is not null)
select  DISTINCT
    PERCENTILE_CONT(0.50)
    WITHIN GROUP (ORDER BY [days late])
    OVER () AS median_delivery_days
 from cte
where order_delivered_customer_date > order_estimated_delivery_date
--p50 = 5  p75 = 11  p90 = 21  p95 = 29
--Among orders that missed the estimated delivery date, the median delay was 5 days.
--75% of late orders were delayed by 11 days or less,
-- while the most severe delays extended to 29 days or more for the top 5%.

SELECT
    r.review_score,
    COUNT(r.review_id) AS [count]
FROM orders o
INNER JOIN reviews r
    ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_delivered_customer_date > o.order_estimated_delivery_date
GROUP BY r.review_score
ORDER BY [count] DESC;
--Late-delivery reviews were heavily skewed toward lower ratings:
-- 54.03% of reviews were 1–2 stars, compared with 34.61% at 4–5 stars.

SELECT
    r.review_score,
    COUNT(r.review_id) AS [count]
FROM orders o
INNER JOIN reviews r
    ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_delivered_customer_date <= o.order_estimated_delivery_date
GROUP BY r.review_score
ORDER BY [count] DESC;
-- Late deliveries were strongly associated with poorer customer ratings.
-- Among reviewed late orders, 54.03% received 1–2 stars and 34.61%
-- received 4–5 stars, compared with 9.23% and 82.77%, respectively,
-- for orders delivered on time or early.
-- This shows a strong association between missed delivery expectations
-- and negative customer experience, but does not prove that lateness
-- alone caused the ratings.

with cte as (select customer_unique_id, count(customer_id)[order_count] from customers group by customer_unique_id)
select count(customer_unique_id)[unique customer count], sum(case when order_count = 1 then 1 else 0 end)[one time customer count],
sum(case when order_count > 1 then 1 else 0 end)[repeat customer count] from cte 
--96096  	93099   	2997
-- Customer repeat purchasing was very limited in the dataset:
-- 96.88% of customers placed only one order, while only 3.12%
-- placed more than one order.

with cte as (select customer_unique_id, count(customer_id)[order_count] from customers group by customer_unique_id)
select order_count, count(customer_unique_id)[customer_count] from cte group by order_count
order by order_count
-- Repeat purchasing was shallow. Among 2,997 repeat customers,
-- 91.59% placed exactly two orders, while very few customers
-- made three or more purchases.


with first_orders as ( select c.customer_unique_id, o.order_id, o.order_purchase_timestamp, 
ROW_NUMBER() over(partition by c.customer_unique_id order by o.order_purchase_timestamp, o.order_id)[rn]
from customers c inner join orders o on c.customer_id = o.customer_id),
review_one AS (SELECT order_id,review_score,ROW_NUMBER() OVER(PARTITION BY order_id ORDER BY review_creation_date, review_id) AS rn
FROM reviews),
first_order_review as (select f.customer_unique_id, f.order_id, r.review_score from first_orders f left join 
review_one r on f.order_id = r.order_id where f.rn = 1 and r.rn = 1),
customer_orders as (select customer_unique_id, count(order_id)[order_Count] from first_orders group by customer_unique_id)
select f.review_score,count(c.customer_unique_id)[total customers], sum(case when order_count > 1 then 1 else 0 end)[repeat customers]
from customer_orders c left join first_order_review f on c.customer_unique_id = f.customer_unique_id 
WHERE f.review_score IS NOT NULL group by f.review_score
order by review_score
--We do not find a meaningful association between first-order review rating and whether a customer returns.

with latedelivery as (select *,
datediff(DAY,order_estimated_delivery_date, order_delivered_customer_date)[difference] from orders),
repeat as (select customer_unique_id, count(customer_id)[order_count] from customers group by customer_unique_id),
first_order as (select c.customer_id, c.customer_unique_id, o.order_id, ROW_NUMBER() over(partition by c.customer_unique_id 
order by o.order_purchase_timestamp)[rn]
from orders o inner join customers c on c.customer_id = o.customer_id where order_status = 'delivered'
AND order_delivered_customer_date IS NOT NULL)
select f.customer_unique_id, f.order_id[first_order_id], l.difference, r.order_count
from latedelivery l inner join first_order f on l.order_id = f.order_id inner join repeat r on r.customer_unique_id = f.customer_unique_id
where f.rn = 1


with latedelivery as (select *,
datediff(DAY,order_estimated_delivery_date, order_delivered_customer_date)[difference] from orders),
repeat as (select customer_unique_id, count(customer_id)[order_count] from customers group by customer_unique_id),
first_order as (select c.customer_id, c.customer_unique_id, o.order_id,o.order_delivered_customer_date,o.order_estimated_delivery_date, ROW_NUMBER() over(partition by c.customer_unique_id 
order by o.order_purchase_timestamp)[rn]
from orders o inner join customers c on c.customer_id = o.customer_id where order_status = 'delivered'
AND order_delivered_customer_date IS NOT NULL)
select (case when f.order_delivered_customer_date > f.order_estimated_delivery_date then 'Late' else 'On-time/Early' end)[first delivery], 
sum(case when r.order_count = 1 then 1 else 0 end)[one time],
sum(case when r.order_count > 1 then 1 else 0 end)[repeat]
from latedelivery l inner join first_order f on l.order_id = f.order_id inner join repeat r on r.customer_unique_id = f.customer_unique_id
where f.rn = 1
group by (case when f.order_delivered_customer_date > f.order_estimated_delivery_date then 'Late' else 'On-time/Early' end)
-- Customers whose first delivered order was late had a 2.71% repeat rate,
-- compared with 3.23% among customers whose first order was delivered
-- on time or early. The difference is small, so first-order delivery
-- lateness does not show a strong relationship with repeat purchasing
-- in this dataset.

with latedelivery as (select *,
datediff(DAY,order_estimated_delivery_date, order_delivered_customer_date)[difference] from orders
where order_status = 'delivered' and order_delivered_carrier_date is not null)
select sum(payment_value)[total payment value] from latedelivery l inner join payments p 
on p.order_id = l.order_id where  l.order_delivered_customer_date > l.order_estimated_delivery_date
-- Late deliveries were associated with R$1,351,452.81 in payment value,
-- equivalent to approximately 8.76% of delivered-order payment value.
-- This is slightly higher than the 8.11% share of delivered orders that
-- were late, indicating that late orders represented a modestly higher
-- share of payment value than of order volume.

select avg(DATEDIFF(DAY,order_purchase_timestamp, order_delivered_carrier_date))[avg difference] from orders 
where order_status = 'delivered' and order_delivered_carrier_date is not null
--3

select avg(DATEDIFF(DAY,order_delivered_carrier_date,order_delivered_customer_date))[avg difference] from orders 
where order_status = 'delivered' and order_delivered_carrier_date is not null and order_delivered_customer_date is not null
--9

select avg(DATEDIFF(DAY,order_delivered_carrier_date,order_estimated_delivery_date))[avg difference] from orders 
where order_status = 'delivered' and order_delivered_carrier_date is not null and order_estimated_delivery_date is not null
--21

select avg(DATEDIFF(DAY,order_purchase_timestamp, order_delivered_carrier_date))[avg difference] from orders 
where order_status = 'delivered' and order_delivered_carrier_date is not null
and order_delivered_customer_date > order_estimated_delivery_date
--5

select avg(DATEDIFF(DAY,order_delivered_carrier_date,order_delivered_customer_date))[avg difference] from orders 
where order_status = 'delivered' and order_delivered_carrier_date is not null
and order_delivered_customer_date > order_estimated_delivery_date
--25

select avg(DATEDIFF(DAY,order_delivered_carrier_date,order_estimated_delivery_date))[avg difference] from orders 
where order_status = 'delivered' and order_delivered_carrier_date is not null
and order_delivered_customer_date > order_estimated_delivery_date
--16
--For orders that miss the promised delivery date, the much larger difference appears in the carrier/transit stage rather than the seller-handling stage.


with latedelivery as (select *,
datediff(DAY,order_estimated_delivery_date, order_delivered_customer_date)[difference] from orders
where order_status = 'delivered' and order_delivered_customer_date is not null)
select c.customer_state,count(o.order_id)[delivered orders], sum(case when o.order_delivered_customer_date > o.order_estimated_delivery_date then 1 else 0 end)[late orders],
(sum(case when o.order_delivered_customer_date > o.order_estimated_delivery_date then 1 else 0 end)*100.0)/count(o.order_id) [late%]
from latedelivery o inner join customers c on c.customer_id = o.customer_id group by c.customer_state
order by [late orders] desc
-- Late-delivery exposure is geographically uneven. Rio de Janeiro (RJ)
-- combines substantial order volume with a high late-delivery rate of 13.47%,
-- while São Paulo (SP) contributes the largest absolute number of late orders
-- (2,387) despite a lower late-delivery rate of 5.89%.
-- Together, RJ and SP account for approximately 51.8% of all late orders.

select DATEADD(MONTH,-6,max(order_purchase_timestamp)) from orders

--How many customers had their first recorded purchase early enough to have a full 6-month observation window?
with purchase as (select c.customer_unique_id, o.order_purchase_timestamp,
ROW_NUMBER() over(partition by c.customer_unique_id order by o.order_purchase_timestamp,o.order_id)[rn]
from orders o inner join customers c on o.customer_id = c.customer_id)
select count(customer_unique_id) from purchase where rn = 1 and 
order_purchase_timestamp <= '2018-04-17 17:30:18'
-- 68,169 unique customers had their first recorded purchase on or before
-- 17 April 2018, providing a six-month observation window for repeat purchasing.
-- This is a preliminary eligibility count, not the final six-month retention denominator,
-- because the query does not restrict the first order to successfully delivered orders.

-- TASK 5: FINAL SIX-MONTH CUSTOMER RETENTION
with cte as (select c.customer_unique_id,ROW_NUMBER() over(partition by c.customer_unique_id order by o.order_purchase_timestamp,o.order_id)[rn],o.order_purchase_timestamp
from orders o inner join customers c on c.customer_id = o.customer_id where o.order_status = 'delivered' and o.order_delivered_customer_date is not null)
select count(customer_unique_id) from cte where rn = 1 and 
order_purchase_timestamp <= '2018-04-17 17:30:18'

-- 65,917 customers had their first successfully delivered order
-- on or before 17 April 2018, making them eligible for a
-- six-month retention observation window.

with cte as (select c.customer_unique_id,ROW_NUMBER() over(partition by c.customer_unique_id order by o.order_purchase_timestamp,o.order_id)[rn],o.order_purchase_timestamp
from orders o inner join customers c on c.customer_id = o.customer_id where o.order_status = 'delivered' and o.order_delivered_customer_date is not null)
SELECT COUNT(DISTINCT customer_unique_id) from cte where rn = 1 and  order_purchase_timestamp <= '2018-04-17 17:30:18'
AND EXISTS (
    SELECT 1
    FROM orders o2
    INNER JOIN customers c2
        ON c2.customer_id = o2.customer_id
    WHERE c2.customer_unique_id = cte.customer_unique_id
      AND o2.order_status = 'delivered'
      AND o2.order_delivered_customer_date IS NOT NULL
      AND o2.order_purchase_timestamp > cte.order_purchase_timestamp
      AND o2.order_purchase_timestamp <=
          DATEADD(MONTH, 6, cte.order_purchase_timestamp))
-- Among 65,917 customers eligible for a full six-month observation window,
-- 1,773 placed another successfully delivered order within six months.
-- The six-month customer retention rate was 2.69%, indicating very low
-- repeat purchasing in the observed customer population.

WITH delivered_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date
    FROM orders o
    INNER JOIN customers c
        ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_purchase_timestamp IS NOT NULL
),
ranked_orders AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp, order_id
        ) AS rn
    FROM delivered_orders
),
eligible AS (
    SELECT *,
        CASE
            WHEN order_delivered_customer_date > order_estimated_delivery_date
                THEN 'Late'
            ELSE 'On-time/Early'
        END AS first_delivery
    FROM ranked_orders
    WHERE rn = 1
      AND order_purchase_timestamp <= '2018-04-17 17:30:18'
)
SELECT
    e.first_delivery,
    COUNT(DISTINCT e.customer_unique_id) AS [eligible customers],
    COUNT(DISTINCT CASE
        WHEN d.customer_unique_id IS NOT NULL
        THEN e.customer_unique_id
    END) AS [returning customers],
    CAST(
        COUNT(DISTINCT CASE
            WHEN d.customer_unique_id IS NOT NULL
            THEN e.customer_unique_id
        END) * 100.0
        / COUNT(DISTINCT e.customer_unique_id)
        AS DECIMAL(6,2)
    ) AS [six month retention %]
FROM eligible e
LEFT JOIN delivered_orders d
    ON d.customer_unique_id = e.customer_unique_id
   AND d.order_purchase_timestamp > e.order_purchase_timestamp
   AND d.order_purchase_timestamp <=
       DATEADD(MONTH, 6, e.order_purchase_timestamp)
GROUP BY e.first_delivery
ORDER BY e.first_delivery;
---- Customers whose first delivered order was late had a six-month retention
-- rate of 2.39%, compared with 2.72% for customers whose first order
-- was delivered on time or early. The difference was small (0.33 percentage
-- points), providing no strong descriptive evidence of an association
-- between first-delivery lateness and six-month retention.
