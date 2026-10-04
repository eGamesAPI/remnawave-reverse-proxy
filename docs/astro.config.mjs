// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightScrollToTop from 'starlight-scroll-to-top';
import starlightUtils from "@lorenzo_lewis/starlight-utils";
import starlightLinksValidator from 'starlight-links-validator'
import starlightSidebarTopics from 'starlight-sidebar-topics';
import starlightKbd from 'starlight-kbd';
import autoImport from 'astro-auto-import';
import starlightGitHubAlerts from 'starlight-github-alerts';
import starlightThemeGalaxy from 'starlight-theme-galaxy';

// https://astro.build/config
export default defineConfig({
	site: 'https://wiki.egam.es',
	vite: {
		resolve: {
			alias: {
				'@components': '/src/components',
			},
		},
	},
	integrations: [
		autoImport({
			imports: [],
		}),
		starlight({
			// код-блоки всегда тёмные терминалы — в светлой теме страницы
			// они остаются «экранами», как и окна Terminal.astro
			expressiveCode: {
				themes: ['github-dark-high-contrast'],
			},
			components: {
				SiteTitle: './src/components/SiteTitle.astro',
				Hero: './src/components/HeroSplash.astro',
				SocialIcons: './src/components/SocialIcons.astro',
			},
			plugins: [
				starlightThemeGalaxy(),
				starlightGitHubAlerts(),
				starlightScrollToTop({
					showTooltip: false,
					borderRadius: '25',
				}),
				starlightKbd({
					globalPicker: false,
					types: [
						{ id: 'mac', label: 'macOS' },
						{ id: 'windows', label: 'Windows', default: true },
						{ id: 'linux', label: 'Linux' },
					]
				})
			],
			head: [
				// Plausible Analytics
				{
				tag: 'script',
				attrs: {
					async: true,
					src: 'https://ps.log.rw/js/pa-TLPk4Xvnye6Dh8hvwvH9n.js',
				},
				},
				{
					tag: 'script',
					content:
						'window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};plausible.init()',
				},
				// collapse toggle for the left sidebar (desktop): icon-only button
				// pinned to the bottom of the pane (after the scrolling
				// content), the class on <html> is restored before first paint
				{
					tag: 'script',
					content:
						'(function(){var k="rr-sb-collapsed";try{if(localStorage.getItem(k)==="1")document.documentElement.classList.add(k)}catch(e){}document.addEventListener("DOMContentLoaded",function(){var pane=document.querySelector("sl-sidebar-pane.sidebar-pane");if(!pane||pane.querySelector(".rr-sb-foot"))return;var b=document.createElement("button");b.type="button";b.className="rr-sb-foot";var ru=document.documentElement.lang==="ru";var label=ru?"Свернуть меню":"Collapse sidebar";b.setAttribute("aria-label",label);b.title=label;b.innerHTML=\'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m11 17-5-5 5-5"/><path d="m18 17-5-5 5-5"/></svg>\';b.addEventListener("click",function(){var on=document.documentElement.classList.toggle(k);try{localStorage.setItem(k,on?"1":"0")}catch(e){}});pane.appendChild(b);});})();',
				},
			],
			title: 'Remnawave Reverse-Proxy',
			logo: {
				src: './src/assets/logo.webp',
			},
			customCss: [
				'./src/styles/custom.css',
			],
			defaultLocale: 'root', // https://starlight.astro.build/guides/i18n/
			locales: {
				root: {
					label: 'English',
					lang: 'en', // lang is required for the root locales
				},
				'ru': {
					label: 'Русский',
					lang: 'ru',
				},
			},
			editLink: {
				baseUrl: "https://github.com/eGamesAPI/remnawave-reverse-proxy/edit/main/docs/",
			},
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/eGamesAPI/remnawave-reverse-proxy/' },
				{ icon: 'telegram', label: 'Telegram', href: 'https://t.me/remnawave_reverse' },
				{ icon: 'seti:zip', label: 'Used resources', href: '/contribution/resources' }
			],
			sidebar: [
				{
					label: 'Introduction', translations: { ru: 'Введение' },
					items: [
						{ label: 'Overview', slug: 'introduction/overview', translations: { ru: 'Обзор' } },
					],
				},
				{
					label: 'Installation', translations: { ru: 'Установка' },
					items: [
						{ label: 'Requirements', slug: 'installation/requirements', translations: { ru: 'Обязательные условия' } },
						{ label: 'Panel and node', slug: 'installation/panel-and-node', translations: { ru: 'Панель и нода' } },
						{ label: 'Panel and subscription page', slug: 'installation/panel-and-sub', translations: { ru: 'Панель и страница подписки' } },
						{ label: 'Panel only', slug: 'installation/panel-only', translations: { ru: 'Только панель' } },
						{ label: 'Subscription page only', slug: 'installation/sub-only', translations: { ru: 'Только страница подписки' } },
						{ label: 'Node only', slug: 'installation/node-only', translations: { ru: 'Только нода' } },
						{ label: 'Add node to panel', slug: 'installation/add-node', translations: { ru: 'Добавление ноды в панель' } },
					],
				},
				{
					label: 'Configuration Remnawave', translations: { ru: 'Настройка Remnawave' },
					items: [
						{ label: 'How to replace a domain', slug: 'configuration/how-to-replace-a-domain', translations: { ru: 'Как изменить домен' } },
						{ label: 'Access to Prometheus metrics', slug: 'configuration/prometheus-metrics', translations: { ru: 'Метрики Prometheus' } },
						{ label: 'External access to API', slug: 'configuration/external-api', translations: { ru: 'Внешний доступ к API' } },
					],
				},
				{
					label: 'Modules', translations: { ru: 'Модули' },
					items: [
					{ label: 'Warp Native', slug: 'configuration/warp-native', translations: { ru: 'Warp Native' } },
					{ label: 'Node plugins', slug: 'configuration/node-plugins', translations: { ru: 'Плагины ноды' }, badge: { text: { en: 'NEW', ru: 'Новое' }, variant: 'caution' } },
					{ label: 'Xray Checker', slug: 'configuration/xray-checker', translations: { ru: 'Xray Checker' }, badge: { text: { en: 'NEW', ru: 'Новое' }, variant: 'caution' } },
					{ label: 'SSH remote access', slug: 'configuration/ssh-remote-access', translations: { ru: 'SSH-доступ к серверам' }, badge: { text: { en: 'NEW', ru: 'Новое' }, variant: 'caution' } },
					{ label: 'Server routing (bridge)', slug: 'configuration/server-routing', translations: { ru: 'Серверный роутинг (мост)' }, badge: { text: { en: 'NEW', ru: 'Новое' }, variant: 'caution' } },
					{ label: 'NetBird module', slug: 'configuration/netbird-module', translations: { ru: 'Модуль NetBird' }, badge: { text: { en: 'NEW', ru: 'Новое' }, variant: 'caution' } },
					{ label: 'Backup and Restore', slug: 'configuration/backup-restore', translations: { ru: 'Бэкап и восстановление' }, badge: { text: { en: 'NEW', ru: 'Новое' }, variant: 'caution' } },
					],
				},
				{
					label: 'Configuration', translations: { ru: 'Настройка' },
					items: [
						{ label: 'Certwarden', slug: 'configuration/certwarden', translations: { ru: 'Certwarden' } },
							{ label: 'Beszel', slug: 'configuration/beszel', translations: { ru: 'Beszel' } },
						{ label: 'Netbird', slug: 'configuration/netbird', translations: { ru: 'Netbird' } },
						{ label: 'Monitoring with Grafana and Victoria Metrics', slug: 'configuration/grafana-monitoring-setup', translations: { ru: 'Мониторинг Grafana и Victoria Metrics' } },
						{ label: 'SWAG (Secure Web Application Gateway)', slug: 'configuration/swag', translations: { ru: 'SWAG (Secure Web Application Gateway)' } },
							],
				},
				{
					label: 'Troubleshooting', translations: { ru: 'Устранение неполадок' },
					items: [
						{ label: 'Common issues', slug: 'troubleshooting/common-issues', translations: { ru: 'Частые проблемы' } },
						{ label: 'Docker related issues', slug: 'troubleshooting/docker-issues', translations: { ru: 'Проблемы Docker' } },
						// { label: 'Logs', slug: 'troubleshooting/logs', translations: { ru: 'Логи' } },
					],
				},
				{
					label: 'Contribution', translations: { ru: 'Помощь в разработке' },
					items: [
						{ label: 'Contributors', slug: 'contribution/contributors', translations: { ru: 'Участники разработки' } },
						{ label: 'Contribution Guide', slug: 'contribution/guide', translations: { ru: 'Руководство по внесению изменений' } },
					],
				},
			],
		}),
	],
});
