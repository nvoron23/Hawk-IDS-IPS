var config = {
	min_brutes: 0,
	max_brutes: 2000000000,
	min_failed: 0,
	max_failed: 2000000000,
	min_blocked: 0,
	max_blocked: 2000000000,
	chartLineSize: 1,
	chartDotSize: 5,
}

// The names of the parameters we use
var parameter_names = new Array('min_brutes', 'max_brutes', 'min_failed', 'max_failed', 'min_blocked', 'max_blocked');

Ext.apply(Ext.form.VTypes, {
	minMaxNumber: function(value, field) {
		if (value == '' || value == null) {
			this.minMaxNumberText = 'This field must not be left blank.';
			return false;
		}
		value = Number(value);
		if ( value < 0) {
			this.minMaxNumberText = 'This field must contain a positive integer.';
			return false;
		}
		var other;
		if (/^min/.test(field.getName())) {
			other = Ext.getCmp(field.getName().replace('min', 'max'));
			if (other.getValue() < value) {
				this.minMaxNumberText = 'This field must contain a smaller value than the corresponding max field.';
				return false;
			}
		} else {
			other = Ext.getCmp(field.getName().replace('max', 'min'));
			if (other.getValue() > value) {
				this.minMaxNumberText = 'This field must contain a larger value than the corresponding min field.';
				return false;
			}
		}
		if (!this.validatedOpposite) {
			this.validatedOpposite = true;
			other.validate();
		} else {
			this.validatedOpposite = false;
		}
		return true;
	},
	minMaxNumberText: 'The field must contain a positive number, greater than or equal to the corresponding min value or less than or equal to the correspondong max value.',
	validatedOpposite: false,
});

Ext.onReady(function () {

	Ext.QuickTips.init();

	var stores = new Array();
	var charts = new Array();

	bigStore = new Ext.data.JsonStore({
		url: '../cgi-bin/master.pl',
		baseParams: {
			txt: 1,
		//	debug: 1,
			min_brutes: config['min_brutes'],
			max_brutes: config['max_brutes'],
			min_failed: config['min_failed'],
			max_failed: config['max_failed'],
			min_blocked: config['min_blocked'],
			max_blocked: config['max_blocked'],
		},
		root: 'servers',
		totalProperty: 'total',
		propertyId: 'num',
		fields: [
			{name: 'chartData', mapping: 'data'},
			{name: 'serverName', mapping: 'name'},
		],
		listeners: {
			load: function() {
				var i;
				showCharts(bigStore.getCount());
				for (i=0; i < bigStore.getCount(); i++) {
					stores[i].loadData(bigStore.getAt(i).data.chartData);
					charts[i].setTitle('<a href="http://' + bigStore.getAt(i).data.serverName +
						'/~sentry/cgi-bin/hawk-web.pl">' + bigStore.getAt(i).data.serverName + '</a>');
				}
				hideCharts(bigStore.getCount());
			}
		}
	});

	//Hides charts.
	//showing_count is the number of graphics to be shown
	//after the functon has completed.
	function hideCharts(showing_count) {
		while (charts.length > showing_count) {
			charts.pop().destroy();
			stores.pop().destroy();
		}
	}

	function showCharts(count) {
		for (var i = charts.length; i < count; i++) {
			stores.push(new Ext.data.JsonStore({
				fields: ['hour', 'brutes', 'failed', 'blocked'],
			}));

			charts.push( new Ext.Panel({
				title: 'servername' + i,
				bodyBorder: false,
				style: {
					float: 'left',
					'margin-top': 20,
					'margin-left': 20,
					'margin-bottom': i <= 1 ? 0 : 20,
					'margin-right': i%2 == 0 ? 0 : 20,
				},
				items: 	new Ext.chart.LineChart({
					store: stores[i],
					url:'ext-3.1.1/resources/charts.swf',
					xField: 'hour',
					height: '220px',
					width: '438px',
					series: [{
							type: 'line',
							displayName: 'bruteforce attempts',
							yField: 'brutes',
							style: {
								color:0xff0000,
								size: config.chartDotSize,
								lineSize: config.chartLineSize,
							}
						},{
							type:'line',
							displayName: 'failed attempts',
							yField: 'failed',
							style: {
								color: 0x00ff00,
								size: config.chartDotSize,
								lineSize: config.chartLineSize,
							}
						},{
							type:'line',
							displayName: 'blocked ip addresses',
							yField: 'blocked',
							style: {
								color: 0x0000ff,
								size: config.chartDotSize,
								lineSize: config.chartLineSize,
							}
						}],
				})
			}));
			Ext.getCmp('main-panel').add(charts[i]);
		}
		Ext.getCmp('main-panel').doLayout();
	}

	var settings_form = new Ext.FormPanel({
		id: 'hawk_settings_form',
		frame: true,
		width: 210,
		autoHeight:true,
		monitorValid: true,
		items: [
			new Ext.form.NumberField({
				width: 40,
				id: 'min_brutes_i',
				labelStyle: 'width:150px',
				fieldLabel: 'Min bruteforce attempts',
				allowBlank: false,
				value: config['min_brutes'],//min_bruteforce,
				vtype:'minMaxNumber',
			}),
			new Ext.form.NumberField({
				width: 40,
				id: 'max_brutes_i',
				labelStyle: 'width:150px',
				fieldLabel: 'Max bruteforce attempts',
				allowBlank: false,
				value: config['max_brutes'],//max_bruteforce,
				vtype:'minMaxNumber',
			}),
			new Ext.form.NumberField({
				width: 40,
				id:'min_failed_i',
				labelStyle: 'width:150px',
				fieldLabel:'Min failed attempts',
				allowBlank: false,
				value: config['min_failed'],//min_failed,
				vtype:'minMaxNumber',
			}),
			new Ext.form.NumberField({
				width: 40,
				id:'max_failed_i',
				labelStyle: 'width:150px',
				fieldLabel:'Max failed attempts',
				allowBlank: false,
				value: config['max_failed'],//max_failed,
				vtype:'minMaxNumber',
			}),
			new Ext.form.NumberField({
				width: 40,
				id:'min_blocked_i',
				labelStyle: 'width:150px',
				fieldLabel:'Min blocked IP addresses',
				allowBlank:false,
				value: config['min_blocked'],//min_blocked,
				vtype:'minMaxNumber',
			}),
			new Ext.form.NumberField({
				width: 40,
				id:'max_blocked_i',
				labelStyle: 'width:150px',
				fieldLabel:'Max blocked IP addresses',
				allowBlank:false,
				value: config['max_blocked'],//max_blocked,
				vtype:'minMaxNumber',
			}),
			],
		buttons: [{
			text: "Save",
			formBind: true,
			handler: function() {
						for (var i = 0; i < parameter_names.length; i++) {
							bigStore.baseParams[parameter_names[i]] = Number(Ext.getCmp(parameter_names[i] + '_i').getValue());
						}
						Ext.getCmp('server-name').setValue('');
						delete bigStore.baseParams['server'];
						bigStore.load({params: {start:0, limit: 4} });
						mySettings.hide();
				}
			},{
			text: "Close",
			handler: function() {
					for (var i = 0; i < parameter_names.length; i++) {
						config[parameter_names[i]] = bigStore.baseParams[parameter_names[i]];
					}
					mySettings.hide();
				}
			}]
	});

	var mySettings = new Ext.Window({
		id: 'settings',
		xtype: 'form',
		title:"Hawk Settings",
		shadow: true,
		closeAction:'hide',
		resizable: false,
		items: [ settings_form ]
	});

	var mainPanel = new Ext.Panel({
		id:'main-panel',
		title: 'aaa',
		width: 944,
		height: 610,
		renderTo: 'main',
		style: {
			'margin-top': '10px',
			'margin-left': 'auto',
			'margin-right': 'auto',
		},
		tools:[{
				id:'gear',
				handler: function(){
					mySettings.show();
				}
			}],
		bbar:{
				xtype: 'paging',
				id: 'pager',
				store: bigStore,
				pageSize: 4,
				displayInfo: true,
				displayMsg: 'Displaying info for servers {0} - {1} of {2}',
				emptyMsg: "No servers match the search criteria",
				renderTo: mainPanel,
				items:[
					'-', {
						id: 'showall',
						pressed: false,
						text: 'Show all',
						handler: function() {
							for (var i = 0; i < parameter_names.length; i++) {
								delete bigStore.baseParams[parameter_names[i]];
							}
							Ext.getCmp('server-name').setValue('');
							delete bigStore.baseParams['server'];
							bigStore.load({params: {start: 0, limit: 4} });
						}
					}, '-', '->', '-', '<label for="server-name">Search: </label>',
					new Ext.form.TriggerField({
						id: 'server-name',
						name: 'server-name',
						emptyText: 'Filter by server name',
						triggerClass: 'x-form-search-trigger',
						onTriggerClick: function(){
							bigStore.baseParams['server'] = this.getValue();
							bigStore.load({params: {start:0, limit: 4} });
						},
					}),
				],
			},
		});
	showCharts(4);
	bigStore.load({params: {start:0, limit: 4} });
});
