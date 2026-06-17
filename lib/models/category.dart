import 'package:flutter/material.dart';

class Cat { final String id, name, icon; final Color color; Cat(this.id, this.name, this.icon, this.color); }

final cats = <Cat>[Cat("food","Food & Dining","🍕",const Color(0xFFFF6B35)),Cat("transport","Transport","🚗",const Color(0xFF00D4FF)),Cat("shopping","Shopping","🛍️",const Color(0xFFA855F7)),Cat("entertainment","Entertainment","🎬",const Color(0xFFF43F5E)),Cat("groceries","Groceries","🥦",const Color(0xFF22C55E)),Cat("bills","Bills & Utilities","💡",const Color(0xFFEAB308)),Cat("health","Health","💊",const Color(0xFF06B6D4)),Cat("education","Education","📚",const Color(0xFF8B5CF6)),Cat("subscriptions","Subscriptions","📱",const Color(0xFFEC4899)),Cat("travel","Travel","✈️",const Color(0xFFF97316)),Cat("rent","Rent & Housing","🏠",const Color(0xFF14B8A6)),Cat("savings","Savings","💰",const Color(0xFF10B981)),Cat("personal","Personal","✨",const Color(0xFFD946EF)),Cat("gifts","Gifts","🎁",const Color(0xFFF59E0B)),Cat("other","Other","📌",const Color(0xFF64748B))];

final iCats = <Cat>[Cat("salary","Salary","💼",const Color(0xFF22C55E)),Cat("freelance","Freelance","💻",const Color(0xFF3B82F6)),Cat("business","Business","🏢",const Color(0xFF8B5CF6)),Cat("investment","Investment","📈",const Color(0xFF10B981)),Cat("refund","Refund","↩️",const Color(0xFF06B6D4)),Cat("other_income","Other","💵",const Color(0xFF64748B))];

Cat? fCat(String id) => [...cats, ...iCats].where((c) => c.id == id).firstOrNull;
